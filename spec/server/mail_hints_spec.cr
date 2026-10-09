require "../spec_helper"

module TinrelayMailHintsSpec
  TLS_ROOT = File.join(__DIR__, "../support/proxy_tls")

  class Sink
    getter bodies = [] of String
    getter headers = [] of HTTP::Headers
    property status = 202
    property gate : Channel(Nil)? = nil
    property drop = false
    property malformed = false
    @server : HTTP::Server
    @port : Int32

    def initialize(certificate = "mail_hint.crt")
      context = OpenSSL::SSL::Context::Server.new
      # Public localhost test certificate; reuses the existing public fixture key.
      context.certificate_chain = File.join(TLS_ROOT, certificate)
      context.private_key = File.join(TLS_ROOT, "fixture.key")
      @server = HTTP::Server.new do |http|
        bodies << http.request.body.not_nil!.gets_to_end
        headers << http.request.headers.dup
        gate.try(&.receive)
        http.response.headers["Connection"] = "close"
        http.response.version = "SYNTHETIC-PRIVATE-WIRE-MARKER" if malformed
        if drop
          http.response.output = IO::Memory.new
        else
          http.response.status_code = status
          http.response.headers["Location"] = url if status == 302
          http.response.print("synthetic-private-response")
        end
      end
      @port = @server.bind_tls("127.0.0.1", 0, context).port
      spawn { @server.listen }
    end

    def url : String
      "https://localhost:#{@port}/hint"
    end

    def close : Nil
      @server.close
    end
  end

  def self.with_sink(certificate = "mail_hint.crt", trust = certificate, &)
    prior = ENV["SSL_CERT_FILE"]?
    ENV["SSL_CERT_FILE"] = File.join(TLS_ROOT, trust)
    sink = Sink.new(certificate)
    yield sink
  ensure
    sink.try(&.close)
    ENV["SSL_CERT_FILE"] = prior
  end

  def self.destination(url : String, ship = "alpha") : Tinrelay::MailHintDestination
    Tinrelay::MailHintDestination.new(ship, url, "OAI-Sites-Authorization", "Bearer fixture-only")
  end

  def self.envelope(root : String, client : Tinrelay::Client) : Tinrelay::SignedRelayEnvelope
    capture = TinrelaySpec::CaptureRemote.new(client.keyring.data.server)
    sender = Tinrelay::Client.new(client.keyring, capture)
    sender.send("probe@#{client.keyring.data.ship}", "Synthetic mail hint proof", "probe")
    capture.captured.last
  end

  def self.retained(api : Tinrelay::API)
    api.database.db.query_all(
      "SELECT id, state, ciphertext, signature, envelope_digest FROM transmissions ORDER BY id",
      as: {String, String, Bytes?, Bytes?, Bytes}
    )
  end
end

describe "operator-owned mail hints" do
  it "stops an old sweep after reload removes or replaces its next destination" do
    [false, true].each do |replace|
      TinrelayMailHintsSpec.with_sink do |old_sink|
        TinrelayMailHintsSpec.with_sink do |new_sink|
          initial = Tinrelay::TinrelaydConfig.new(mail_hints: [
            TinrelayMailHintsSpec.destination(old_sink.url),
            TinrelayMailHintsSpec.destination(old_sink.url, "beta"),
          ])
          TinrelaySpec.with_server(runtime_policy: initial) do |root, origin, api, config_path|
            alpha = TinrelaySpec.admit(root, origin, "alpha")
            beta = TinrelaySpec.admit(root, origin, "beta")
            api.store.accept(TinrelayMailHintsSpec.envelope(root, alpha))
            envelope = TinrelayMailHintsSpec.envelope(root, beta)
            api.store.accept(envelope)
            before = TinrelayMailHintsSpec.retained(api)
            held = Channel(Nil).new(1)
            old_sink.gate = held
            done = Channel(Nil).new(1)
            spawn do
              api.mail_hints_once
              done.send(nil)
            end
            TinrelaySpec.eventually { old_sink.bodies.size == 1 }
            destinations = [] of Tinrelay::MailHintDestination
            if replace
              destinations << Tinrelay::MailHintDestination.new(
                "beta", new_sink.url, "Authorization", "Bearer replacement-fixture"
              )
            end
            File.write(config_path.not_nil!,
              Tinrelay::TinrelaydConfig.new(mail_hints: destinations).to_json)
            api.reload_configuration
            old_sink.gate = nil
            held.send(nil)
            TinrelaySpec.receive(done)
            old_sink.bodies.should eq([
              %({"contract":"tinrelay-mail-hint-v1","local_ship":"alpha"}),
            ])
            TinrelayMailHintsSpec.retained(api).should eq(before)
            api.mail_hints_once
            if replace
              new_sink.bodies.should eq([
                %({"contract":"tinrelay-mail-hint-v1","local_ship":"beta"}),
              ])
              new_sink.headers.last["Authorization"].should eq("Bearer replacement-fixture")
            else
              new_sink.bodies.should be_empty
            end
            TinrelayMailHintsSpec.retained(api).should eq(before)
            event = beta.radio_poll(Tinrelay::Spool.new(File.join(root, "beta-inbox")))
            event.not_nil!.source_id.should eq(envelope.transmission_id)
            api.database.db.query_one(
              "SELECT state, ciphertext, signature FROM transmissions WHERE id = ?",
              envelope.transmission_id, as: {String, Bytes?, Bytes?}
            ).should eq({"collected", nil, nil})
          end
        end
      end
    end
  end

  it "requires unique HTTPS hint destinations and one safe authentication header" do
    defaults = Tinrelay::TinrelaydConfig.from_json("{}")
    defaults.validated_mail_hints.should be_empty
    destination = TinrelayMailHintsSpec.destination("https://sink.example/hint")
    config = Tinrelay::TinrelaydConfig.new(mail_hints: [destination])
    config.validated_mail_hints.size.should eq(1)
    expect_raises(Tinrelay::Invalid) do
      Tinrelay::TinrelaydConfig.new(mail_hints: [destination, destination]).validated_mail_hints
    end
    ["http://sink.example/hint", "https://user:secret@sink.example/hint",
     "https://sink.example/hint?secret=x", "https://sink.example/elsewhere",
     "https://sink.example/hint#fragment"].each do |url|
      expect_raises(Tinrelay::Invalid) do
        Tinrelay::TinrelaydConfig.new(
          mail_hints: [TinrelayMailHintsSpec.destination(url)]
        ).validated_mail_hints
      end
    end
    ["Host", "Content-Length", "Content-Type", "bad header"].each do |header|
      invalid = Tinrelay::MailHintDestination.new(
        "alpha", "https://sink.example/hint", header, "fixture"
      )
      expect_raises(Tinrelay::Invalid) { invalid.validate! }
    end
    invalid = Tinrelay::MailHintDestination.new(
      "alpha", "https://sink.example/hint", "Authorization", "fixture\r\nInjected: value"
    )
    expect_raises(Tinrelay::Invalid) { invalid.validate! }
  end

  it "repeats body-free hints without changing ciphertext and refinds mail after reopening" do
    TinrelayMailHintsSpec.with_sink do |sink|
      TinrelaySpec.with_server do |root, origin, api|
        alpha = TinrelaySpec.admit(root, origin, "alpha")
        TinrelaySpec.admit(root, origin, "beta")
        envelope = TinrelayMailHintsSpec.envelope(root, alpha)
        api.store.accept(envelope)
        before = TinrelayMailHintsSpec.retained(api)
        log = IO::Memory.new
        destination = TinrelayMailHintsSpec.destination(sink.url)
        hints = Tinrelay::MailHints.new(api.store, log: log)
        hints.notify([destination, TinrelayMailHintsSpec.destination(sink.url, "beta")])
        hints.notify([destination])
        sink.status = 503
        hints.notify([destination])
        sink.drop = true
        hints.notify([destination])
        sink.drop = false
        sink.status = 202

        reopened = Tinrelay::Database.new(api.config.database_path)
        begin
          Tinrelay::MailHints.new(
            Tinrelay::Store.new(reopened), log: log
          ).notify([destination])
        ensure
          reopened.close
        end
        sink.bodies.should eq(Array.new(5, %({"contract":"tinrelay-mail-hint-v1",) +
                                           %("local_ship":"alpha"})))
        sink.headers.each do |headers|
          headers["OAI-Sites-Authorization"].should eq("Bearer fixture-only")
        end
        TinrelayMailHintsSpec.retained(api).should eq(before)
        log.to_s.should_not contain("fixture-only")
        log.to_s.should_not contain("localhost")
        log.to_s.should_not contain("synthetic-private-response")
        outcomes = log.to_s.lines.map { |line| JSON.parse(line)["outcome"].as_s }
        outcomes.should eq(%w[accepted accepted not_accepted transport_failed accepted])
        api.store.pending_mail?("alpha", envelope.expires_at).should be_false

        spool = Tinrelay::Spool.new(File.join(root, "inbox"))
        alpha.radio_poll(spool).not_nil!.source_id.should eq(envelope.transmission_id)
        hints.notify([destination])
        sink.bodies.size.should eq(5)
        api.database.db.query_one(
          "SELECT state, ciphertext, signature FROM transmissions WHERE id = ?",
          envelope.transmission_id, as: {String, Bytes?, Bytes?}
        ).should eq({"collected", nil, nil})
      end
    end
  end

  it "includes uncollected hails but excludes their acknowledged and expired state" do
    TinrelayMailHintsSpec.with_sink do |sink|
      TinrelaySpec.with_server do |root, origin, api|
        alpha = TinrelaySpec.admit(root, origin, "alpha")
        beta = TinrelaySpec.admit(root, origin, "beta")
        beta.hail("alpha")
        before = api.database.db.query_all(
          "SELECT id, collected_at, allowed_at, signature FROM hails",
          as: {String, Int64?, Int64?, Bytes}
        )
        destination = TinrelayMailHintsSpec.destination(sink.url)
        hints = Tinrelay::MailHints.new(api.store, log: IO::Memory.new)
        hints.notify([destination])
        api.database.db.query_all(
          "SELECT id, collected_at, allowed_at, signature FROM hails",
          as: {String, Int64?, Int64?, Bytes}
        ).should eq(before)
        api.store.pending_mail?("alpha", Time.utc.to_unix + 3_601).should be_false
        event = alpha.radio_poll(Tinrelay::Spool.new(File.join(root, "inbox"))).not_nil!
        event.kind.should eq("hail")
        hints.notify([destination])
        sink.bodies.size.should eq(1)
      end
    end
  end

  it "reports authentication refusal safely and never follows a redirect" do
    TinrelayMailHintsSpec.with_sink do |sink|
      TinrelaySpec.with_server do |root, origin, api|
        alpha = TinrelaySpec.admit(root, origin, "alpha")
        api.store.accept(TinrelayMailHintsSpec.envelope(root, alpha))
        before = TinrelayMailHintsSpec.retained(api)
        log = IO::Memory.new
        hints = Tinrelay::MailHints.new(api.store, log: log)
        destination = TinrelayMailHintsSpec.destination(sink.url)
        [401, 403, 302, 429].each do |status|
          sink.status = status
          hints.notify([destination])
        end
        outcomes = log.to_s.lines.map { |line| JSON.parse(line) }
        outcomes.map(&.["outcome"].as_s).should eq(
          ["authentication_failed", "authentication_failed", "not_accepted", "not_accepted"]
        )
        outcomes.map(&.["http_status"].as_i).should eq([401, 403, 302, 429])
        sink.bodies.size.should eq(4)
        TinrelayMailHintsSpec.retained(api).should eq(before)
      end
    end
  end

  it "bounds a slow callback without blocking admission or retaining a transaction" do
    TinrelayMailHintsSpec.with_sink do |sink|
      TinrelaySpec.with_server do |root, origin, api|
        alpha = TinrelaySpec.admit(root, origin, "alpha")
        first = TinrelayMailHintsSpec.envelope(root, alpha)
        api.store.accept(first)
        sink.gate = Channel(Nil).new(1)
        log = IO::Memory.new
        hints = Tinrelay::MailHints.new(
          api.store, timeout: 100.milliseconds, log: log
        )
        completed = Channel(Nil).new(1)
        spawn do
          hints.notify([TinrelayMailHintsSpec.destination(sink.url)])
          completed.send(nil)
        end
        TinrelaySpec.eventually { sink.bodies.size == 1 }
        # Both normal admission and a queued read complete while callback is held.
        second = TinrelayMailHintsSpec.envelope(root, alpha)
        response = TinrelaySpec.post(origin, "/v1/transmissions", second.to_json)
        response.status_code.should eq(202)
        api.store.wait_once(TinrelaySpec.radio_wait_request(alpha, 0)).envelope.not_nil!
          .transmission_id.should eq(first.transmission_id)
        TinrelaySpec.receive(completed, 1.second)
        log.to_s.should contain("transport_failed")
        api.database.db.scalar("SELECT COUNT(*) FROM transmissions WHERE state = 'pending'")
          .should eq(2_i64)
        sink.gate.not_nil!.send(nil)
      end
    end
  end

  it "verifies both certificate trust and hostname before sending authentication" do
    [{"mail_hint.crt", "fixture.crt"}, {"fixture.crt", "fixture.crt"}].each do |pair|
      TinrelayMailHintsSpec.with_sink(pair[0], pair[1]) do |sink|
        TinrelaySpec.with_server do |root, origin, api|
          alpha = TinrelaySpec.admit(root, origin, "alpha")
          api.store.accept(TinrelayMailHintsSpec.envelope(root, alpha))
          before = TinrelayMailHintsSpec.retained(api)
          log = IO::Memory.new
          Tinrelay::MailHints.new(api.store, log: log).notify(
            [TinrelayMailHintsSpec.destination(sink.url)]
          )
          sink.bodies.should be_empty
          log.to_s.should contain("transport_failed")
          log.to_s.should_not contain("fixture-only")
          TinrelayMailHintsSpec.retained(api).should eq(before)
        end
      end
    end
  end

  it "sanitizes a malformed HTTPS response and retains mail for another attempt" do
    TinrelayMailHintsSpec.with_sink do |sink|
      TinrelaySpec.with_server do |root, origin, api|
        alpha = TinrelaySpec.admit(root, origin, "alpha")
        api.store.accept(TinrelayMailHintsSpec.envelope(root, alpha))
        before = TinrelayMailHintsSpec.retained(api)
        log = IO::Memory.new
        sink.malformed = true
        hints = Tinrelay::MailHints.new(api.store, log: log)
        hints.notify([TinrelayMailHintsSpec.destination(sink.url)])
        log.to_s.should contain("transport_failed")
        log.to_s.should_not contain("SYNTHETIC-PRIVATE-WIRE-MARKER")
        sink.malformed = false
        hints.notify([TinrelayMailHintsSpec.destination(sink.url)])
        log.to_s.should contain("accepted")
        TinrelayMailHintsSpec.retained(api).should eq(before)
      end
    end
  end
end
