require "../spec_helper"

module TinrelayRegistrationCIDRSpec
  FORBIDDEN = %({"error":"registration_forbidden",) +
              %("message":"registration is not available from this source"})

  def self.write_config(path : String, mode : String,
                        trusted : Array(String), denied : Array(String)) : Nil
    File.write(path, {
      registration: {
        deny_cidrs: denied,
      },
      client_address: {
        mode: mode, trusted_ingress_cidrs: trusted,
      },
    }.to_json)
  end

  def self.with_server(mode : String, trusted : Array(String),
                       denied : Array(String), &)
    root = TinrelaySpec.temporary_root
    path = File.join(root, "tinrelayd.json")
    write_config(path, mode, trusted, denied)
    config = Tinrelay::ServerConfig.new(
      "127.0.0.1", 0, File.join(root, "service.db"), System.cpu_count,
      Tinrelay::DEFAULT_PERMANENT_METADATA_LIMIT, path
    )
    api = Tinrelay::API.new(config)
    server = HTTP::Server.new(api.handler)
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    begin
      yield "http://127.0.0.1:#{address.port}", api
    ensure
      server.close
      api.close
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  def self.claim(ship : String) : Tinrelay::ShipClaim
    owner = Tinrelay::Crypto.signing_keypair
    signing = Tinrelay::Crypto.signing_keypair
    encryption = Tinrelay::Crypto.box_keypair
    certificate = Tinrelay::ShipRadioCertificate.new(
      ship, 1, Tinrelay::Crypto.b64(signing.public_key),
      Tinrelay::Crypto.b64(encryption.public_key), Time.utc.to_unix, 1
    )
    certificate.owner_signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(certificate.unsigned_bytes, owner.secret_key)
    )
    Tinrelay::ShipClaim.new(
      ship, Tinrelay::Crypto.b64(owner.public_key), certificate
    )
  end

  def self.submit(origin : String, body : String,
                  client_addresses = [] of String) : HTTP::Client::Response
    headers = HTTP::Headers{
      "Content-Type"        => "application/json",
      "X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s,
    }
    client_addresses.each do |address|
      headers.add(Tinrelay::ClientAddressPolicy::HEADER, address)
    end
    HTTP::Client.post("#{origin}/v1/join", headers, body)
  end

  def self.assert_forbidden(response : HTTP::Client::Response) : Nil
    response.status_code.should eq(403)
    response.body.should eq(FORBIDDEN)
    response.headers["Retry-After"]?.should be_nil
  end
end

describe "registration CIDR denial" do
  it "denies the normalized socket peer before reading a claim body" do
    TinrelayRegistrationCIDRSpec.with_server(
      "direct", [] of String, ["127.0.0.0/8"]
    ) do |origin, api|
      oversized = "x" * (Tinrelay::API::MAX_REQUEST_BYTES + 1)
      response = TinrelayRegistrationCIDRSpec.submit(
        origin, oversized, ["198.51.100.9"]
      )
      TinrelayRegistrationCIDRSpec.assert_forbidden(response)
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(0_i64)
      api.database.db.scalar("SELECT COUNT(*) FROM registration_events").should eq(0_i64)
      metrics = api.metrics.render(api.store, api.handoffs)
      metrics.should contain(
        %(tinrelay_registrations_total{outcome="cidr_denied"} 1)
      )
    end
  end

  it "ignores a spoofed client header in direct mode" do
    TinrelayRegistrationCIDRSpec.with_server(
      "direct", [] of String, ["192.0.2.0/24"]
    ) do |origin, api|
      response = TinrelayRegistrationCIDRSpec.submit(
        origin,
        TinrelayRegistrationCIDRSpec.claim("direct-ship").to_json,
        ["192.0.2.9"]
      )
      response.status_code.should eq(201)
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(1_i64)
    end
  end

  it "fails malformed and denied trusted-proxy sources closed" do
    TinrelayRegistrationCIDRSpec.with_server(
      "trusted_proxy", ["127.0.0.0/8"], ["192.0.2.0/24", "2001:db8::/32"]
    ) do |origin, api|
      [
        [] of String,
        ["192.0.2.8", "198.51.100.8"],
        ["192.0.2.8, 198.51.100.8"],
        ["client.example"],
        ["192.0.2.8"],
        ["2001:0db8::8"],
      ].each do |addresses|
        response = TinrelayRegistrationCIDRSpec.submit(
          origin, "not JSON", addresses
        )
        TinrelayRegistrationCIDRSpec.assert_forbidden(response)
      end

      accepted = TinrelayRegistrationCIDRSpec.submit(
        origin,
        TinrelayRegistrationCIDRSpec.claim("proxied-ship").to_json,
        ["198.51.100.8"]
      )
      accepted.status_code.should eq(201)
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(1_i64)
      metrics = api.metrics.render(api.store, api.handoffs)
      metrics.should contain(
        %(tinrelay_registrations_total{outcome="cidr_denied"} 2)
      )
      metrics.should contain(
        %(tinrelay_registrations_total{outcome="invalid"} 4)
      )
      metrics.should contain(
        %(tinrelay_registrations_total{outcome="accepted"} 1)
      )
    end
  end

  it "rejects a client address supplied by an untrusted ingress" do
    TinrelayRegistrationCIDRSpec.with_server(
      "trusted_proxy", ["192.0.2.0/24"], [] of String
    ) do |origin, api|
      response = TinrelayRegistrationCIDRSpec.submit(
        origin, "not JSON", ["198.51.100.8"]
      )
      TinrelayRegistrationCIDRSpec.assert_forbidden(response)
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(0_i64)
      metrics = api.metrics.render(api.store, api.handoffs)
      metrics.should contain(
        %(tinrelay_registrations_total{outcome="cidr_denied"} 0)
      )
      metrics.should contain(
        %(tinrelay_registrations_total{outcome="invalid"} 1)
      )
      metrics.should contain(
        %(tinrelay_registrations_total{outcome="accepted"} 0)
      )
    end
  end

  it "derives canonical IPv4 and IPv6 source buckets after normalization" do
    Tinrelay::LiteralIP.source_bucket(
      Tinrelay::LiteralIP.parse("::ffff:192.0.2.8")
    ).should eq("192.0.2.8/32")
    Tinrelay::LiteralIP.source_bucket(
      Tinrelay::LiteralIP.parse("2001:0db8:1:2:3:4:5:6")
    ).should eq("2001:db8:1:2::/64")

    mapped = Tinrelay::IPNetwork.new("::ffff:192.0.2.0/24")
    mapped.includes?(Tinrelay::LiteralIP.parse("192.0.2.8")).should be_true
    expect_raises(Tinrelay::Invalid) do
      Tinrelay::IPNetwork.new("::ffff:192.0.2.0/120")
    end
  end
end
