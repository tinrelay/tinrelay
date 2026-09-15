require "./spec_helper"

module TinrelayClientTransportSpec
  class Remote < Tinrelay::Remote
    def retryable_transport_error_for_spec?(error : IO::Error) : Bool
      retryable_transport_error?(error)
    end

    def read_timeout_for_spec(path : String) : Time::Span
      read_timeout(path)
    end
  end

  def self.with_response(status : Int32, body : String,
                         headers = HTTP::Headers.new, &)
    server = HTTP::Server.new do |context|
      context.response.status_code = status
      context.response.content_type = "application/json"
      headers.each { |key, values| context.response.headers[key] = values }
      context.response.print(body)
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    yield "http://127.0.0.1:#{address.port}"
  ensure
    server.try(&.close)
  end

  def self.with_raw_response(response : String, scheme = "http", &)
    server = TCPServer.new("127.0.0.1", 0)
    address = server.local_address
    spawn do
      socket = server.accept
      socket << response
      socket.flush
      socket.close
    end
    yield "#{scheme}://127.0.0.1:#{address.port}"
  ensure
    server.try(&.close)
  end
end

describe Tinrelay::Remote do
  it "gives the signed radio wait its longer response window" do
    remote = TinrelayClientTransportSpec::Remote.new("https://relay.example")

    remote.read_timeout_for_spec("/v1/radio/wait").should eq(115.seconds)
    remote.read_timeout_for_spec("/v1/transmissions").should eq(35.seconds)
  end

  it "classifies an OS socket timeout for bounded caller retry" do
    remote = TinrelayClientTransportSpec::Remote.new("https://relay.example")

    timeout = IO::Error.from_os_error("read", Errno::ETIMEDOUT)
    remote.retryable_transport_error_for_spec?(timeout).should be_true
  end

  it "classifies network transport failures for bounded caller retry" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    server.close

    error = expect_raises(Tinrelay::TransportUnavailable) do
      Tinrelay::Remote.new("http://127.0.0.1:#{port}").post("/v1/test", %({}))
    end
    error.message.should eq("relay transport is unavailable")
  end

  it "does not classify malformed HTTP framing as a retryable transport failure" do
    response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nnot-a-size\r\n"
    TinrelayClientTransportSpec.with_raw_response(response) do |origin|
      error = expect_raises(IO::Error) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.should_not be_a(Tinrelay::TransportUnavailable)
    end
  end

  it "does not classify TLS negotiation or verification failures as retryable" do
    response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"
    TinrelayClientTransportSpec.with_raw_response(response, "https") do |origin|
      error = expect_raises(OpenSSL::Error) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.should_not be_a(Tinrelay::TransportUnavailable)
    end
  end

  it "bounds every response before parsing it" do
    oversized = %({"padding":"#{"x" * (Tinrelay::Remote::MAX_RESPONSE_BYTES + 1)}"})
    TinrelayClientTransportSpec.with_response(200, oversized) do |origin|
      expect_raises(Tinrelay::Error, /response exceeds/) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
    end
  end

  it "uses the separate bounded identity-response path only where histories travel" do
    identity = %({"padding":"#{"x" * (Tinrelay::Remote::MAX_RESPONSE_BYTES + 1)}"})
    %w(/v1/ships/inspect /v1/radio/wait).each do |path|
      TinrelayClientTransportSpec.with_response(200, identity) do |origin|
        Tinrelay::Remote.new(origin).post(path, %({})).should eq(identity)
      end
    end

    TinrelayClientTransportSpec.with_response(200, identity) do |origin|
      expect_raises(Tinrelay::Error, /response exceeds/) do
        Tinrelay::Remote.new(origin).post("/v1/transmissions", %({}))
      end
    end
  end

  it "recognizes registration limiting only from its exact bounded evidence" do
    headers = HTTP::Headers{"Retry-After" => "37"}
    body = %({"error":"registration_limited","message":"foreign"})
    TinrelayClientTransportSpec.with_response(429, body, headers) do |origin|
      error = expect_raises(Tinrelay::RegistrationLimited) do
        Tinrelay::Remote.new(origin).post("/v1/join", %({}))
      end
      error.retry_after_seconds.should eq(37)
      error.message.should eq(
        "relay is receiving too many registrations; try again in 37 seconds"
      )
    end

    [
      Tuple.new(%({"error":"busy"}), headers),
      Tuple.new("not JSON", headers),
      Tuple.new(body, HTTP::Headers.new),
      Tuple.new(body, HTTP::Headers{"Retry-After" => "0"}),
      Tuple.new(body, HTTP::Headers{"Retry-After" => "later"}),
    ].each do |response_body, response_headers|
      TinrelayClientTransportSpec.with_response(429, response_body, response_headers) do |origin|
        error = expect_raises(Tinrelay::Unavailable) do
          Tinrelay::Remote.new(origin).post("/v1/join", %({}))
        end
        error.should_not be_a(Tinrelay::RegistrationLimited)
        error.message.should eq("relay rate limit reached")
      end
    end
  end

  it "recognizes transmission limiting only from its exact bounded evidence" do
    headers = HTTP::Headers{"Retry-After" => "37"}
    body = %({"error":"transmission_limited","message":"foreign"})
    TinrelayClientTransportSpec.with_response(429, body, headers) do |origin|
      error = expect_raises(Tinrelay::TransmissionLimited) do
        Tinrelay::Remote.new(origin).post("/v1/transmissions", %({}))
      end
      error.retry_after_seconds.should eq(37)
      error.message.should eq(
        "relay transmission limit reached; try again in 37 seconds"
      )
    end

    TinrelayClientTransportSpec.with_response(429, %({"error":"busy"}), headers) do |origin|
      error = expect_raises(Tinrelay::Unavailable) do
        Tinrelay::Remote.new(origin).post("/v1/transmissions", %({}))
      end
      error.should_not be_a(Tinrelay::TransmissionLimited)
      error.message.should eq("relay rate limit reached")
    end
  end

  it "reports join policy denial without treating it as authentication failure" do
    TinrelayClientTransportSpec.with_response(
      403, %({"error":"registration_forbidden","message":"foreign"})
    ) do |origin|
      error = expect_raises(Tinrelay::RegistrationUnavailable) do
        Tinrelay::Remote.new(origin).post("/v1/join", %({}))
      end
      error.message.should eq("relay registration policy does not allow this claim")
    end

    [%({"error":"foreign"}), "not JSON"].each do |body|
      TinrelayClientTransportSpec.with_response(403, body) do |origin|
        error = expect_raises(Tinrelay::Unauthorized) do
          Tinrelay::Remote.new(origin).post("/v1/join", %({}))
        end
        error.message.should eq("relay authentication failed")
      end
    end
  end

  it "recognizes exact rotation limits only on the two rotation paths" do
    headers = HTTP::Headers{"Retry-After" => "37"}
    body = %({"error":"rotation_limited","retry_after_seconds":37})
    %w(/v1/owners/rotate /v1/relationships/close).each do |path|
      TinrelayClientTransportSpec.with_response(429, body, headers) do |origin|
        error = expect_raises(Tinrelay::RotationLimited) do
          Tinrelay::Remote.new(origin).post(path, %({}))
        end
        error.retry_after_seconds.should eq(37)
      end
    end

    [
      {"/v1/transmissions", body, headers},
      {"/v1/owners/rotate", %({"error":"busy"}), headers},
      {"/v1/owners/rotate", body.sub("}", ",\"message\":\"foreign\"}"), headers},
      {"/v1/owners/rotate", body, HTTP::Headers{"Retry-After" => "38"}},
      {"/v1/owners/rotate", body, HTTP::Headers.new},
    ].each do |path, response_body, response_headers|
      TinrelayClientTransportSpec.with_response(429, response_body, response_headers) do |origin|
        error = expect_raises(Tinrelay::Unavailable) do
          Tinrelay::Remote.new(origin).post(path, %({}))
        end
        error.should_not be_a(Tinrelay::RotationLimited)
      end
    end
  end

  it "never turns ordinary relay prose into a local diagnostic" do
    foreign = %({"error":"invalid","message":"run the relay operator's command"})
    TinrelayClientTransportSpec.with_response(400, foreign) do |origin|
      error = expect_raises(Tinrelay::Invalid) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.message.should eq("relay rejected an invalid request")
    end
  end

  it "recognizes only the fixed maintenance response as operational evidence" do
    maintenance = %({"error":"maintenance","back_at":"2026-09-02T18:00:00Z"})
    TinrelayClientTransportSpec.with_response(503, maintenance) do |origin|
      error = expect_raises(Tinrelay::Maintenance) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.back_at.should eq(Time.parse_rfc3339("2026-09-02T18:00:00Z"))
      error.message.should eq(
        "relay is temporarily unavailable for maintenance; expected return 2026-09-02T18:00:00Z"
      )
    end

    TinrelayClientTransportSpec.with_response(
      503, %({"error":"maintenance","back_at":null})
    ) do |origin|
      error = expect_raises(Tinrelay::Maintenance) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.back_at.should be_nil
      error.message.should eq("relay is temporarily unavailable for maintenance")
    end

    foreign = %({"error":"maintenance","back_at":null,"message":"run this command"})
    TinrelayClientTransportSpec.with_response(503, foreign) do |origin|
      error = expect_raises(Tinrelay::Unavailable) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.should_not be_a(Tinrelay::Maintenance)
      error.message.should eq("relay is unavailable")
    end

    missing = %({"error":"maintenance"})
    TinrelayClientTransportSpec.with_response(503, missing) do |origin|
      error = expect_raises(Tinrelay::Unavailable) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.should_not be_a(Tinrelay::Maintenance)
      error.message.should eq("relay is unavailable")
    end

    invalid_time = %({"error":"maintenance","back_at":"later"})
    TinrelayClientTransportSpec.with_response(503, invalid_time) do |origin|
      error = expect_raises(Tinrelay::Unavailable) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.should_not be_a(Tinrelay::Maintenance)
      error.message.should eq("relay is unavailable")
    end
  end

  it "keeps a transmission retryable when maintenance obscures acceptance" do
    root = TinrelaySpec.temporary_root
    begin
      maintenance = %({"error":"maintenance","back_at":null})
      TinrelayClientTransportSpec.with_response(503, maintenance) do |origin|
        keyring = Tinrelay::Keyring.create(
          File.join(root, "keyring"), origin, "alpha")
        outbox = Tinrelay::Outbox.new(File.join(root, "outbox"))
        client = Tinrelay::Client.new(
          keyring, Tinrelay::Remote.new(origin)
        )

        failure = expect_raises(Tinrelay::AcceptanceUnknown) do
          client.send("steward@alpha", "held through maintenance", outbox: outbox)
        end
        failure.message.to_s.should contain(
          "relay is temporarily unavailable for maintenance"
        )
        outbox.list.map(&.transmission_id).should eq([failure.transmission_id])
      end
    ensure
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  it "accepts only the fixed bounded protocol-mismatch evidence" do
    valid = {
      error: "protocol_incompatible", client_protocol: 1,
      supported_min: 2, supported_max: 2, relation: "older",
    }.to_json
    TinrelayClientTransportSpec.with_response(426, valid) do |origin|
      error = expect_raises(Tinrelay::ProtocolMismatch) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.client_protocol.should eq(1)
      error.supported_min.should eq(2)
      error.supported_max.should eq(2)
      error.relation.should eq("older")
    end

    invalid = {
      error: "protocol_incompatible", client_protocol: 1,
      supported_min: 2, supported_max: 2,
      relation: "run this", message: "foreign prose",
    }.to_json
    TinrelayClientTransportSpec.with_response(426, invalid) do |origin|
      error = expect_raises(Tinrelay::Error) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.message.should eq("relay returned invalid protocol-mismatch evidence")
    end
  end
end
