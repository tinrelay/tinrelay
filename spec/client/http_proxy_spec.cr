require "../spec_helper"
require "../support/http_proxy"
require "./cli_spec"

class ProxyAckFailureRemote < Tinrelay::Remote
  getter cleanup_attempts = 0

  def initialize(origin : String, @failure : Tinrelay::ProxyFailure)
    super(origin)
  end

  def post(path : String, body : String) : String
    if path.in?({"/v1/transmissions/ack", "/v1/hails/ack"})
      @cleanup_attempts += 1
      raise @failure
    end
    super
  end
end

describe "durable receive with proxy cleanup failure" do
  it "returns verified transmission and hail pointers despite transient cleanup failure" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(root, origin, "beta", alpha)
      failure = Tinrelay::ProxyFailure.new("connect", "timeout", true)
      remote = ProxyAckFailureRemote.new(origin, failure)
      receiver = Tinrelay::Client.new(alpha.keyring, remote)
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))
      sent = beta.send("probe@alpha", "Synthetic proxy cleanup qualification", "probe")

      event = receiver.radio_wait(spool, hold_seconds: 0)
      event.kind.should eq("transmission")
      record = spool.get(event.kind, event.source_id).as(Tinrelay::TransmissionSpoolRecord)
      record.signed_transmission.body.should eq("Synthetic proxy cleanup qualification")
      record.routed.should be_false
      receiver.radio_poll(spool).not_nil!.source_id.should eq(event.source_id)
      remote.cleanup_attempts.should eq(1)
      api.database.db.scalar("SELECT state FROM transmissions WHERE id = ?",
        sent.transmission_id).as(String).should eq("pending")
      alpha.acknowledge(sent.transmission_id)

      gamma = Tinrelay::Client.join(File.join(root, "gamma.keyring"), origin, "gamma")
      gamma.hail("alpha")
      hail = receiver.radio_collect(spool, hold_seconds: 0)
      hail.kind.should eq("hail")
      spool.get(hail.kind, hail.source_id).should be_a(Tinrelay::HailSpoolRecord)
      spool.list.count { |item| !item.routed }.should eq(2)
      remote.cleanup_attempts.should eq(2)
    end
  end

  it "keeps permanent proxy cleanup refusals visible without losing the durable record" do
    TinrelaySpec.with_server do |root, origin, _api|
      alpha = Tinrelay::Client.join(File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(root, origin, "beta", alpha)
      beta.send("probe@alpha", "Synthetic permanent refusal qualification", "probe")
      remote = ProxyAckFailureRemote.new(origin,
        Tinrelay::ProxyFailure.new("connect", "rejected", false, 407))
      receiver = Tinrelay::Client.new(alpha.keyring, remote)
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))

      error = expect_raises(Tinrelay::ProxyFailure) do
        receiver.radio_wait(spool, hold_seconds: 0)
      end
      error.retryable.should be_false
      error.status_code.should eq(407)
      record = spool.list.first.as(Tinrelay::TransmissionSpoolRecord)
      record.signed_transmission.body.should eq("Synthetic permanent refusal qualification")
      record.routed.should be_false
      receiver.radio_wait(spool, hold_seconds: 0).source_id.should eq(record.source_id)
      remote.cleanup_attempts.should eq(1)
    end
  end
end

describe "TinRelay HTTP proxy selection" do
  it "uses the explicit proxy instead of HTTPS_PROXY without persisting it" do
    previous = ENV["HTTPS_PROXY"]?
    ENV["HTTPS_PROXY"] = "http://environment.invalid:8080"
    remote = Tinrelay::Remote.new("https://relay.invalid",
      http_proxy: "http://explicit.invalid:8081")
    remote.proxied?.should be_true
    direct = Tinrelay::Remote.new("https://relay.invalid", http_proxy: "")
    direct.proxied?.should be_false
    Tinrelay::Remote.new("https://relay.invalid").proxied?.should be_true
    Tinrelay::Remote.new("http://127.0.0.1:8080").proxied?.should be_false
  ensure
    ENV["HTTPS_PROXY"] = previous
  end

  it "rejects unsupported proxy forms without repeating their credentials" do
    {"https://user:secret@proxy.invalid", "http://user:secret@proxy.invalid/path",
     "http://user:secret@proxy.invalid?token=secret", "http://", "not-a-url"}.each do |value|
      error = expect_raises(Tinrelay::Invalid) { Tinrelay::HTTPProxy.new(value) }
      error.message.not_nil!.should_not contain("secret")
      error.message.not_nil!.should_not contain("proxy.invalid")
    end
  end
end

describe "TinRelay proxy CLI lifecycle" do
  it "reports origin EOF and malformed HTTP safely after verified TLS" do
    TinrelayCliSpec.ensure_binary
    TinrelayProxySpec.with_relay do |root, origin, proxy, _api, _bodies, headers, _lost, failures|
      {:eof => true, :malformed => false}.each do |failure, retryable|
        failures.send(failure)
        started = Time.instant
        result, output, error = TinrelayCliSpec.run(
          ["diagnose", "--server", origin, "--proxy", proxy.url], "", root)
        (Time.instant - started).should be < 5.seconds
        result.exit_code.should eq(2)
        output.should be_empty
        document = JSON.parse(error)
        document["error"].as_s.should eq("proxy_failure")
        document["phase"].as_s.should eq("http")
        document["retryable"].as_bool.should eq(retryable)
        error.should_not contain("PRIVATE-WIRE-MARKER")
        error.should_not contain("fixture-secret")
        error.should_not contain("relay.invalid")
      end
      headers.size.should eq(2)
      proxy.requests.size.should eq(2)
      remote = Tinrelay::Remote.new(origin, http_proxy: proxy.url)
      expect_raises(Tinrelay::Invalid) { remote.post("/v1/join", "{}") }
    end
  end

  it "diagnoses using the explicit proxy over the environment without ship state" do
    TinrelayProxySpec.with_relay do |root, origin, proxy, api|
      result, output, error = TinrelayCliSpec.run(
        ["diagnose", "--server", origin, "--proxy", proxy.url], "", root,
        {"HTTPS_PROXY" => "http://unused-secret@environment.invalid:1"})
      result.success?.should be_true
      JSON.parse(output)["transport"].as_s.should eq("http_proxy")
      error.should be_empty
      output.should_not contain("fixture-secret")
      output.should_not contain("relay.invalid")
      api.database.db.scalar("SELECT COUNT(*) FROM ships").as(Int64).should eq(0)
    end
  end

  it "reports a finite wait failure but keeps the collector alive through reconnect" do
    TinrelayProxySpec.with_relay do |root, origin, proxy|
      paths = Tinrelay::LocalPaths.new("alpha", root)
      remote = Tinrelay::Remote.new(origin, http_proxy: proxy.url)
      sender = Tinrelay::Client.join(paths.keyring, origin, "alpha", paths.owner_key, remote)
      args = ["--ship", "alpha", "--proxy", proxy.url, "radio", "wait"]
      proxy.next_action = :drop
      result, _output, error = TinrelayCliSpec.run(args, "", root)
      result.exit_code.should eq(2)
      JSON.parse(error)["phase"].as_s.should eq("connect")
      JSON.parse(error)["retryable"].as_bool.should be_true

      sender.send("tim@alpha", "synthetic collector reconnect proof", "tim")
      proxy.next_action = :drop
      output = IO::Memory.new
      errors = IO::Memory.new
      process = Process.new(TinrelayCliSpec::BINARY,
        ["--ship", "alpha", "--proxy", proxy.url, "radio", "collect"],
        env: {"HOME" => root, "SSL_CERT_FILE" => ENV["SSL_CERT_FILE"]?},
        output: output, error: errors)
      TinrelaySpec.eventually(8.seconds) { output.to_s.includes?("collected") }
      errors.to_s.should contain("proxy_failure")
      errors.to_s.should_not contain("fixture-secret")
      Tinrelay::Spool.new(paths.spool).list.size.should eq(1)
    ensure
      if active = process
        active.terminate
        active.wait
      end
    end
  end

  it "rejects duplicated or invalid proxy arguments without exposing them" do
    root = TinrelaySpec.temporary_root
    bad = "https://fixture-user:fixture-secret@proxy.invalid"
    result, _output, error = TinrelayCliSpec.run(
      ["diagnose", "--server", "https://relay.invalid", "--proxy", bad], "", root)
    result.exit_code.should eq(2)
    error.should_not contain("fixture-secret")
    error.should_not contain("proxy.invalid")
    result, _output, error = TinrelayCliSpec.run(
      ["diagnose", "--server", "https://relay.invalid", "--proxy=#{bad}"], "", root)
    result.exit_code.should eq(2)
    error.should_not contain("fixture-secret")
    result, _output, error = TinrelayCliSpec.run(
      ["diagnose", "--server", "https://relay.invalid", "--proxy", bad,
       "--proxy", bad], "", root)
    result.exit_code.should eq(2)
    error.should_not contain("fixture-secret")
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end

describe "TinRelay proxied relay transport" do
  it "performs a delayed CONNECT and read-only health request without credential leakage" do
    TinrelayProxySpec.with_relay do |_root, origin, proxy, _api, _bodies, headers|
      proxy.next_action = :slow
      remote = Tinrelay::Remote.new(origin, http_proxy: proxy.url)
      result = remote.diagnose
      result[:state].should eq("ok")
      result[:transport].should eq("http_proxy")
      result[:elapsed_ms].should be >= 80
      proxy.requests.first.resource.should eq("relay.invalid:#{URI.parse(origin).port}")
      proxy.requests.first.headers["Proxy-Authorization"].should eq(
        "Basic #{Base64.strict_encode("fixture-user:fixture-secret")}")
      headers.first["Proxy-Authorization"]?.should be_nil
    end
  end

  it "reports refused and dropped CONNECTs safely and never calls the origin directly" do
    TinrelayProxySpec.with_relay do |_root, origin, proxy, _api, _bodies, headers|
      remote = Tinrelay::Remote.new(origin, http_proxy: proxy.url)
      proxy.next_action = :refuse
      refused = expect_raises(Tinrelay::ProxyFailure) { remote.diagnose }
      refused.phase.should eq("connect")
      refused.status_code.should eq(407)
      refused.retryable.should be_false
      refused.message.not_nil!.should_not contain("fixture-secret")
      proxy.next_action = :drop
      dropped = expect_raises(Tinrelay::ProxyFailure) { remote.diagnose }
      dropped.phase.should eq("connect")
      dropped.retryable.should be_true
      headers.should be_empty
    end
  end

  it "retains and exact-retries an accepted self-send after a lost origin response" do
    TinrelayProxySpec.with_relay do |root, origin, proxy, api, bodies, _headers, lose_response|
      remote = Tinrelay::Remote.new(origin, http_proxy: proxy.url)
      sender = Tinrelay::Client.join(File.join(root, "alpha.keyring"), origin, "alpha",
        remote: remote)
      sender.keyring.data.to_json.includes?("fixture-secret").should be_false
      outgoing = Tinrelay::OutgoingStore.new(File.join(root, "outgoing"), "alpha")
      lose_response.send(nil)
      expect_raises(Tinrelay::AcceptanceUnknown) do
        sender.send("tim@alpha", "synthetic proxy proof", "tim", outgoing: outgoing)
      end
      record = outgoing.list_outbox.first
      sender.retry(outgoing, record.transmission_id)
      bodies.size.should eq(2)
      bodies[1].should eq(bodies[0])
      outgoing.list_outbox.should be_empty
      outgoing.list_sent.size.should eq(1)
      api.database.db.scalar("SELECT COUNT(*) FROM transmissions").as(Int64).should eq(1)
      spool = Tinrelay::Spool.new(File.join(root, "spool"))
      event = sender.radio_collect(spool)
      event.kind.should eq("transmission")
    end
  end
end
