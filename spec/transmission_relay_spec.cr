require "./spec_helper"

class RelayCaptureRemote < Tinrelay::Remote
  getter captured : Tinrelay::SignedRelayEnvelope?

  def post(path : String, body : String) : String
    if path == "/v1/transmissions"
      @captured = Tinrelay::SignedRelayEnvelope.from_json(body)
      %({"state":"accepted"})
    else
      super
    end
  end
end

class DropAcceptedTransmissionRemote < Tinrelay::Remote
  def post(path : String, body : String) : String
    response = super
    if path == "/v1/transmissions"
      raise IO::Error.new("synthetic accepted response loss")
    end
    response
  end
end

module TinrelayRelaySpec
  def self.admit(root : String, origin : String, ship : String) : Tinrelay::Client
    TinrelaySpec.admit(root, origin, ship)
  end

  def self.trust_locally(sender : Tinrelay::Client,
                         recipient : Tinrelay::Client,
                         label = "steward") : Nil
    radio = recipient.keyring.data.radio!
    sender.keyring.data.contacts << Tinrelay::ShipContact.new(
      recipient.keyring.data.ship,
      recipient.keyring.data.owner_generation,
      recipient.keyring.data.owner_public_key,
      radio.certificate,
      label
    )
    sender.keyring.save
  end

  def self.capture(sender : Tinrelay::Client, origin : String,
                   coordinate : String, body : String) : Tinrelay::SignedRelayEnvelope
    remote = RelayCaptureRemote.new(origin)
    Tinrelay::Client.new(sender.keyring, remote)
      .send(coordinate, body)
    remote.captured.not_nil!
  end

  def self.signed_envelope(sender : Tinrelay::Client,
                           recipient : Tinrelay::Client,
                           created_at : Int64,
                           expires_at : Int64,
                           body : String) : Tinrelay::SignedRelayEnvelope
    sender_radio = sender.keyring.data.radio!
    recipient_radio = recipient.keyring.data.radio!
    transmission_id = Tinrelay::Ids.uuid
    transmission = Tinrelay::SignedTransmission.new(
      transmission_id, sender.keyring.data.ship, sender_radio.generation,
      recipient.keyring.data.ship, recipient_radio.generation,
      created_at, "steward", body, "caller"
    )
    transmission.signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        transmission.signing_bytes,
        Tinrelay::Crypto.unb64(sender_radio.signing.secret_key)
      )
    )
    ciphertext = Tinrelay::Crypto.seal(
      transmission.to_json.to_slice,
      Tinrelay::Crypto.unb64(recipient_radio.encryption.public_key)
    )
    envelope = Tinrelay::SignedRelayEnvelope.new(
      transmission_id, sender.keyring.data.ship, sender_radio.generation,
      recipient.keyring.data.ship, recipient_radio.generation,
      created_at, expires_at, Tinrelay::Crypto.b64(ciphertext)
    )
    envelope.signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        envelope.signing_bytes,
        Tinrelay::Crypto.unb64(sender_radio.signing.secret_key)
      )
    )
    envelope
  end

  def self.resign(sender : Tinrelay::Client, envelope : Tinrelay::SignedRelayEnvelope) : Nil
    radio = sender.keyring.data.radio!
    envelope.signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        envelope.signing_bytes,
        Tinrelay::Crypto.unb64(radio.signing.secret_key)
      )
    )
  end

  def self.elapsed(&) : Time::Span
    started = Time.instant
    yield
    Time.instant - started
  end

  def self.post(origin : String, envelope : Tinrelay::SignedRelayEnvelope,
                source : String? = nil)
    headers = HTTP::Headers{
      "Content-Type"        => "application/json",
      "X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s,
    }
    headers[Tinrelay::ClientAddressPolicy::HEADER] = source if source
    HTTP::Client.post(
      "#{origin}/v1/transmissions",
      headers,
      envelope.to_json
    )
  end

  def self.trust_forwarded_sources(root : String, api : Tinrelay::API) : Nil
    path = File.join(root, "tinrelayd.json")
    config = Tinrelay::TinrelaydConfig.load(path, false).not_nil!
    policy = Tinrelay::TinrelaydConfig::ClientAddress.new(
      "trusted_proxy", ["127.0.0.0/8"]
    )
    File.write(
      path,
      Tinrelay::TinrelaydConfig.new(
        config.registration, policy, config.logging
      ).to_json
    )
    api.reload_configuration
  end

  def self.leave_two_attempts(api : Tinrelay::API, source : String,
                              envelope : Tinrelay::SignedRelayEnvelope) : Nil
    started = Time.instant
    ciphertext_size = Tinrelay::Crypto.unb64(envelope.ciphertext).size
    api.transmission_buckets.admit(
      source,
      Tinrelay::TransmissionTokenBuckets::BYTE_CAPACITY - 2 * ciphertext_size,
      started
    ).should be_nil
    29.times do
      api.transmission_buckets.admit(source, 0, started).should be_nil
    end
  end
end

describe "transmission relay transitions" do
  it "accepts opaquely but stores nothing without a positive relationship" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      gamma = TinrelayRelaySpec.admit(root, origin, "gamma")
      TinrelayRelaySpec.trust_locally(beta, gamma)

      attempt = beta.send("steward@gamma", "guessed but unrelated")
      attempt.submission_evidence[:state].should eq("accepted")
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", attempt.transmission_id
      ).as(Int64).should eq(0)
    end
  end

  it "spools content-free rejection evidence, erases unusable payload, and reaches later traffic" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))

      unusable = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "body must never survive rejection"
      )
      unusable.ciphertext = Tinrelay::Crypto.b64(Tinrelay::Crypto.random(64))
      TinrelayRelaySpec.resign(beta, unusable)
      response = beta.remote.post("/v1/transmissions", unusable.to_json)
      JSON.parse(response)["state"].as_s.should eq("accepted")

      invalid_plaintext = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "body also must not survive invalid plaintext"
      )
      recipient = alpha.keyring.data.radio!
      invalid_plaintext.ciphertext = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.seal(
          "not a TinRelay plaintext".to_slice,
          Tinrelay::Crypto.unb64(recipient.encryption.public_key)
        )
      )
      TinrelayRelaySpec.resign(beta, invalid_plaintext)
      response = beta.remote.post("/v1/transmissions", invalid_plaintext.to_json)
      JSON.parse(response)["state"].as_s.should eq("accepted")
      valid = beta.send("steward@alpha", "valid behind unusable")

      rejected = alpha.radio_wait(spool, hold_seconds: 0)
      rejected.kind.should eq("rejected_transmission")
      rejected.name.should be_nil
      rejected.wrapper.should_not contain("body must never survive rejection")
      rejection_record = spool.get(rejected.kind, rejected.source_id)
        .as(Tinrelay::RejectedTransmissionSpoolRecord)
      rejection_record.rejection_reason.should eq("unusable_envelope")
      api.database.db.query_one(
        "SELECT state, ciphertext IS NULL FROM transmissions WHERE id = ?",
        unusable.transmission_id, as: {String, Int64}
      ).should eq({"collected", 1_i64})

      spool.routed(rejected.kind, rejected.source_id)
      rejected_plaintext = alpha.radio_wait(spool, hold_seconds: 0)
      rejected_plaintext.kind.should eq("rejected_transmission")
      rejected_plaintext.wrapper.should_not contain("body also must not survive")
      api.database.db.query_one(
        "SELECT state, ciphertext IS NULL FROM transmissions WHERE id = ?",
        invalid_plaintext.transmission_id, as: {String, Int64}
      ).should eq({"collected", 1_i64})
      spool.routed(rejected_plaintext.kind, rejected_plaintext.source_id)

      delivered = alpha.radio_wait(spool, hold_seconds: 0)
      delivered.kind.should eq("transmission")
      spool.get(delivered.kind, delivered.source_id).as(Tinrelay::TransmissionSpoolRecord)
        .signed_transmission.body.should eq("valid behind unusable")
      delivered.wrapper.should_not contain("valid behind unusable")
      valid.transmission_id.should_not be_empty
    end
  end

  it "admits only authenticated, size-valid attempts before destination resolution" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )

      31.times do
        api.transmission_buckets.admit("127.0.0.1/32", 1).should be_nil
      end

      oversized = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "oversized attempt"
      )
      oversized.ciphertext = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.random(Tinrelay::Store::MAX_CIPHERTEXT_BYTES + 1)
      )
      TinrelayRelaySpec.resign(beta, oversized)
      TinrelayRelaySpec.post(origin, oversized).status_code.should eq(400)

      forged = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "unauthenticated attempt"
      )
      forged.signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.random(Tinrelay::Crypto::SIGNATURE_BYTES)
      )
      TinrelayRelaySpec.post(origin, forged).status_code.should eq(401)

      discarded = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "discarded attempt"
      )
      discarded.recipient_ship = "not-claimed"
      discarded.recipient_encryption_generation = 1
      TinrelayRelaySpec.resign(beta, discarded)
      TinrelayRelaySpec.post(origin, discarded).status_code.should eq(202)

      limited = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "must be source limited"
      )
      response = TinrelayRelaySpec.post(origin, limited)
      response.status_code.should eq(429)
      response.headers["Retry-After"].should eq("1")
      JSON.parse(response.body)["error"].as_s.should eq("transmission_limited")
    end
  end

  it "charges a recognized exact retransmission without losing its outbox envelope" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      envelope = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "x" * (10 * 1024)
      )
      outbox = Tinrelay::Outbox.new(File.join(root, "retry-outbox"))
      outbox.store(envelope)
      TinrelayRelaySpec.post(origin, envelope).status_code.should eq(202)

      ciphertext_size = Tinrelay::Crypto.unb64(envelope.ciphertext).size
      api.transmission_buckets.admit(
        "127.0.0.1/32",
        Tinrelay::TransmissionTokenBuckets::BYTE_CAPACITY - ciphertext_size
      ).should be_nil
      limited = expect_raises(Tinrelay::TransmissionLimited) do
        beta.retry(outbox, envelope.transmission_id)
      end
      limited.retry_after_seconds.should be > 0
      limited.transmission_id.should eq(envelope.transmission_id)
      outbox.list.map(&.transmission_id).should eq([envelope.transmission_id])
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?",
        envelope.transmission_id
      ).as(Int64).should eq(1_i64)

      changed = Tinrelay::SignedRelayEnvelope.from_json(envelope.to_json)
      changed.signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.random(Tinrelay::Crypto::SIGNATURE_BYTES)
      )
      TinrelayRelaySpec.post(origin, changed).status_code.should eq(409)

      new_envelope = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "y" * (10 * 1024)
      )
      TinrelayRelaySpec.post(origin, new_envelope).status_code.should eq(429)
    end
  end

  it "charges equivalent originals and retries across relay storage outcomes" do
    direct_address = Tinrelay::TinrelaydConfig::ClientAddress.new
    TinrelaySpec.with_server(client_address: direct_address) do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit_contact(root, origin, "beta", alpha)
      gamma = TinrelaySpec.admit_contact(root, origin, "gamma", beta)
      TinrelayRelaySpec.trust_forwarded_sources(root, api)

      durable = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "durable source attempt"
      )
      durable_source = "2001:db8:1::/64"
      TinrelayRelaySpec.leave_two_attempts(api, durable_source, durable)
      2.times do
        TinrelayRelaySpec.post(origin, durable, "2001:db8:1::1").status_code.should eq(202)
      end
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", durable.transmission_id
      ).as(Int64).should eq(1_i64)
      durable_limited = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "d" * (10 * 1024)
      )
      TinrelayRelaySpec.post(
        origin, durable_limited, "2001:db8:1::2"
      ).status_code.should eq(429)

      direct = TinrelayRelaySpec.capture(
        beta, origin, "steward@gamma", "direct source attempt"
      )
      direct_source = "2001:db8:2::/64"
      TinrelayRelaySpec.leave_two_attempts(api, direct_source, direct)
      spool = Tinrelay::Spool.new(File.join(root, "storage-blind-inbox"))
      received = Channel(Tinrelay::RadioEvent).new(1)
      spawn { received.send(gamma.radio_wait(spool, hold_seconds: 5)) }
      TinrelaySpec.eventually { api.handoffs.waiting?("gamma") }
      TinrelayRelaySpec.post(
        origin, direct, "2001:db8:2::1"
      ).status_code.should eq(202)
      event = TinrelaySpec.receive(received)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", direct.transmission_id
      ).as(Int64).should eq(0_i64)
      spool.routed(event.kind, event.source_id)
      TinrelayRelaySpec.post(
        origin, direct, "2001:db8:2::2"
      ).status_code.should eq(202)
      direct_limited = TinrelayRelaySpec.capture(
        beta, origin, "steward@gamma", "r" * (10 * 1024)
      )
      TinrelayRelaySpec.post(
        origin, direct_limited, "2001:db8:2::3"
      ).status_code.should eq(429)

      discarded = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "discarded source attempt"
      )
      discarded.recipient_ship = "not-claimed"
      TinrelayRelaySpec.resign(beta, discarded)
      discarded_source = "2001:db8:3::/64"
      TinrelayRelaySpec.leave_two_attempts(api, discarded_source, discarded)
      2.times do
        TinrelayRelaySpec.post(
          origin, discarded, "2001:db8:3::1"
        ).status_code.should eq(202)
      end
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", discarded.transmission_id
      ).as(Int64).should eq(0_i64)
      discarded_limited = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "x" * (10 * 1024)
      )
      TinrelayRelaySpec.post(
        origin, discarded_limited, "2001:db8:3::2"
      ).status_code.should eq(429)
    end
  end

  it "isolates normalized source buckets through trusted-proxy admission" do
    direct = Tinrelay::TinrelaydConfig::ClientAddress.new
    TinrelaySpec.with_server(client_address: direct) do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit_contact(root, origin, "beta", alpha)
      TinrelayRelaySpec.trust_forwarded_sources(root, api)
      source_a = "2001:db8:1:2::/64"
      last_credit = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "last credit from source A"
      )
      limited = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "x" * (10 * 1024)
      )
      started = Time.instant
      first_size = Tinrelay::Crypto.unb64(last_credit.ciphertext).size
      api.transmission_buckets.admit(
        source_a,
        Tinrelay::TransmissionTokenBuckets::BYTE_CAPACITY - first_size,
        started
      ).should be_nil
      30.times do
        api.transmission_buckets.admit(source_a, 0, started).should be_nil
      end
      TinrelayRelaySpec.post(
        origin, last_credit, "2001:db8:1:2::5"
      ).status_code.should eq(202)

      limited_response = TinrelayRelaySpec.post(
        origin, limited, "2001:db8:1:2::99"
      )
      limited_response.status_code.should eq(429)
      limited_response.headers["Retry-After"].to_i.should be >= 4

      independent = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "different source remains independent"
      )
      TinrelayRelaySpec.post(
        origin, independent, "2001:db8:1:3::5"
      ).status_code.should eq(202)
    end
  end

  it "returns direct, fallback, and discarded acceptance on the same bounded schedule" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      gamma = TinrelayRelaySpec.admit(root, origin, "gamma")
      TinrelayRelaySpec.trust_locally(beta, gamma)
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))

      direct_event = Channel(Tinrelay::RadioEvent).new(1)
      spawn { direct_event.send(alpha.radio_wait(spool, hold_seconds: 5)) }
      TinrelaySpec.eventually { api.handoffs.waiting?("alpha") }
      direct_message = nil.as(Tinrelay::SignedRelayEnvelope?)
      direct = TinrelayRelaySpec.elapsed do
        direct_message = beta.send("steward@alpha", "direct timing")
      end
      received = TinrelaySpec.receive(direct_event)
      spool.routed(received.kind, received.source_id)

      fallback = TinrelayRelaySpec.elapsed do
        beta.send("steward@alpha", "fallback timing")
      end
      discarded = TinrelayRelaySpec.elapsed do
        beta.send("steward@gamma", "discarded timing")
      end

      floor = Tinrelay::API::ACCEPTANCE_TARGET - 25.milliseconds
      durations = [direct, fallback, discarded]
      durations.each { |duration| duration.should be >= floor }
      (durations.max - durations.min).should be < 200.milliseconds
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", direct_message.not_nil!.transmission_id
      ).as(Int64).should eq(0)
    end
  end

  it "rechecks recipient state and pending capacity in the final fallback transaction" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      envelope = TinrelayRelaySpec.capture(beta, origin, "steward@alpha", "prepared before freeze")
      prepared = api.store.prepare(envelope).not_nil!

      api.database.db.exec("UPDATE ships SET state = 'frozen' WHERE name = 'alpha'")
      api.store.persist(prepared).should be_false
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", envelope.transmission_id
      ).as(Int64).should eq(0)

      api.database.db.exec("UPDATE ships SET state = 'active' WHERE name = 'alpha'")
      Tinrelay::Store::MAX_PENDING_PER_SHIP.times do
        id = Tinrelay::Ids.uuid
        now = Time.utc.to_unix
        api.database.db.exec(
          <<-SQL, id, now, now + 3600, now, Tinrelay::Crypto.random(32)
            INSERT INTO transmissions(
              id, sender_ship, sender_signing_generation,
              recipient_ship, recipient_encryption_generation, created_at, expires_at,
              accepted_at, state, ciphertext, signature, envelope_digest
            ) VALUES (?, 'beta', 1, 'alpha', 1, ?, ?, ?, 'pending', X'01', X'01', ?)
          SQL
        )
      end
      second = TinrelayRelaySpec.capture(beta, origin, "steward@alpha", "prepared before full")
      full = api.store.prepare(second).not_nil!
      api.store.persist(full).should be_false
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", second.transmission_id
      ).as(Int64).should eq(0)
    end
  end

  it "does not rewrite the keyring for a routine known-contact send" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      before = File.read(beta.keyring.path)
      TinrelayRelaySpec.capture(beta, origin, "steward@alpha", "no key changes")
      File.read(beta.keyring.path).should eq(before)
    end
  end

  it "uses and enforces the 96-hour durable fallback window" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )

      envelope = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "bounded fallback"
      )
      (envelope.expires_at - envelope.created_at).should eq(
        Tinrelay::FALLBACK_LIFETIME_SECONDS
      )
      api.store.prepare(envelope).should_not be_nil

      too_long = Tinrelay::SignedRelayEnvelope.from_json(envelope.to_json)
      too_long.expires_at += 1
      TinrelayRelaySpec.resign(beta, too_long)
      expect_raises(Tinrelay::Invalid, /within 96 hours/) do
        api.store.prepare(too_long)
      end
    end
  end

  it "admits an absent exact retry after action skew until signed expiry" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      now = Time.utc.to_unix
      created_at = now - Tinrelay::Store::AUTH_SKEW_SECONDS - 1
      envelope = TinrelayRelaySpec.signed_envelope(
        beta, alpha, created_at,
        created_at + Tinrelay::FALLBACK_LIFETIME_SECONDS,
        "delayed but still live"
      )
      outbox = Tinrelay::Outbox.new(File.join(root, "delayed-outbox"))
      outbox.store(envelope)

      beta.retry(outbox, envelope.transmission_id)
      outbox.list.should be_empty
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?",
        envelope.transmission_id
      ).as(Int64).should eq(1_i64)
      TinrelayRelaySpec.post(origin, envelope).status_code.should eq(202)

      overlong = TinrelayRelaySpec.signed_envelope(
        beta, alpha, created_at,
        created_at + Tinrelay::FALLBACK_LIFETIME_SECONDS + 1,
        "overlong exact retry"
      )
      TinrelayRelaySpec.post(origin, overlong).status_code.should eq(400)

      future_within_skew = now + 60
      beyond_relay_window = TinrelayRelaySpec.signed_envelope(
        beta, alpha, future_within_skew,
        future_within_skew + Tinrelay::FALLBACK_LIFETIME_SECONDS,
        "beyond relay window"
      )
      TinrelayRelaySpec.post(origin, beyond_relay_window).status_code.should eq(400)

      expired = TinrelayRelaySpec.signed_envelope(
        beta, alpha,
        now - Tinrelay::FALLBACK_LIFETIME_SECONDS - 1,
        now - 1, "expired exact retry"
      )
      outbox.store(expired)
      expect_raises(Tinrelay::Invalid) do
        beta.retry(outbox, expired.transmission_id)
      end
      outbox.list.should be_empty

      future_created_at = now + Tinrelay::Store::AUTH_SKEW_SECONDS + 60
      future = TinrelayRelaySpec.signed_envelope(
        beta, alpha, future_created_at, future_created_at + 3600,
        "future exact retry"
      )
      TinrelayRelaySpec.post(origin, future).status_code.should eq(400)
    end
  end

  it "replays an aged ambiguous direct handoff without a second pointer" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      now = Time.utc.to_unix
      created_at = now - Tinrelay::Store::AUTH_SKEW_SECONDS - 1
      envelope = TinrelayRelaySpec.signed_envelope(
        beta, alpha, created_at,
        created_at + Tinrelay::FALLBACK_LIFETIME_SECONDS,
        "aged direct retry"
      )
      outbox = Tinrelay::Outbox.new(File.join(root, "direct-outbox"))
      outbox.store(envelope)
      spool = Tinrelay::Spool.new(File.join(root, "direct-inbox"))
      received = Channel(Tinrelay::RadioEvent).new(1)
      spawn { received.send(alpha.radio_wait(spool, hold_seconds: 5)) }
      TinrelaySpec.eventually { api.handoffs.waiting?("alpha") }

      unreliable = Tinrelay::Client.new(
        beta.keyring, DropAcceptedTransmissionRemote.new(origin)
      )
      failure = expect_raises(Tinrelay::AcceptanceUnknown) do
        unreliable.retry(outbox, envelope.transmission_id)
      end
      failure.transmission_id.should eq(envelope.transmission_id)
      failure.message.to_s.should contain("outbox retry #{envelope.transmission_id}")
      failure.message.to_s.should contain("outbox retry #{failure.transmission_id}")
      event = TinrelaySpec.receive(received)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?",
        envelope.transmission_id
      ).as(Int64).should eq(0_i64)
      outbox.list.map(&.transmission_id).should eq([envelope.transmission_id])
      spool.routed(event.kind, event.source_id)

      beta.retry(outbox, envelope.transmission_id)
      outbox.list.should be_empty
      alpha.radio_poll(spool).should be_nil
      spool.next_unrouted.should be_nil
      api.database.db.query_one(
        "SELECT state, ciphertext IS NULL FROM transmissions WHERE id = ?",
        envelope.transmission_id, as: {String, Int64}
      ).should eq({"collected", 1_i64})
    end
  end

  it "retains relay tombstones only through envelope expiry" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      sent = beta.send("steward@alpha", "short retry window", expires_in: 30)
      ack = Tinrelay::TransmissionAck.new(
        sent.transmission_id,
        TinrelaySpec.radio_auth(
          alpha,
          "transmission.ack",
          Tinrelay::Canonical.fields(sent.transmission_id)
        )
      )
      api.store.acknowledge(ack)

      api.store.cleanup(sent.expires_at + 1)
      api.database.db.query_one?(
        "SELECT id FROM transmissions WHERE id = ?", sent.transmission_id, as: String
      ).should be_nil
    end
  end
end
