require "../spec_helper"

class AuthorshipCaptureRemote < Tinrelay::Remote
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

module TinrelayAuthorshipSpec
  def self.capture(sender : Tinrelay::Client, origin : String,
                   body : String) : Tinrelay::SignedRelayEnvelope
    remote = AuthorshipCaptureRemote.new(origin)
    Tinrelay::Client.new(sender.keyring, remote)
      .send("steward@alpha", body, "caller")
    remote.captured.not_nil!
  end

  def self.open(envelope : Tinrelay::SignedRelayEnvelope,
                recipient : Tinrelay::Client) : Tinrelay::SignedTransmission
    radio = recipient.keyring.data.radio!(
      envelope.recipient_encryption_generation
    )
    plaintext = Tinrelay::Crypto.open(
      Tinrelay::Crypto.unb64(envelope.ciphertext),
      Tinrelay::Crypto.unb64(radio.encryption.public_key),
      Tinrelay::Crypto.unb64(radio.encryption.secret_key)
    )
    Tinrelay::SignedTransmission.from_json(String.new(plaintext))
  end

  def self.reseal(envelope : Tinrelay::SignedRelayEnvelope,
                  transmission : Tinrelay::SignedTransmission,
                  sender : Tinrelay::Client,
                  recipient : Tinrelay::Client,
                  resign_inner : Bool) : Tinrelay::SignedRelayEnvelope
    sender_radio = sender.keyring.data.radio!(
      envelope.sender_signing_generation
    )
    if resign_inner
      transmission.signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.sign(
          transmission.signing_bytes,
          Tinrelay::Crypto.unb64(sender_radio.signing.secret_key)
        )
      )
    end
    recipient_radio = recipient.keyring.data.radio!(
      envelope.recipient_encryption_generation
    )
    changed = Tinrelay::SignedRelayEnvelope.from_json(envelope.to_json)
    changed.ciphertext = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.seal(
        transmission.to_json.to_slice,
        Tinrelay::Crypto.unb64(recipient_radio.encryption.public_key)
      )
    )
    changed.signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        changed.signing_bytes,
        Tinrelay::Crypto.unb64(sender_radio.signing.secret_key)
      )
    )
    changed
  end
end

describe "protocol-1 ship authorship" do
  it "domain-separates inner provenance from the sealed relay emission" do
    signing = Tinrelay::Crypto.signing_keypair
    transmission = Tinrelay::SignedTransmission.new(
      Tinrelay::Ids.uuid, "alpha", 1,
      "beta", 1, Time.utc.to_unix, "steward", "same facts"
    )
    envelope = Tinrelay::SignedRelayEnvelope.new(
      transmission.transmission_id, "alpha", 1,
      "beta", 1, transmission.created_at, transmission.created_at + 3600,
      Tinrelay::Crypto.b64(Tinrelay::Crypto.random(64))
    )
    inner_signature = Tinrelay::Crypto.sign(
      transmission.signing_bytes, signing.secret_key
    )
    Tinrelay::Crypto.verify(
      envelope.signing_bytes, inner_signature, signing.public_key
    ).should be_false
  end

  it "rejects changed outer route or ciphertext before destination decryption" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      original = TinrelayAuthorshipSpec.capture(beta, origin, "sealed emission")

      changed_route = Tinrelay::SignedRelayEnvelope.from_json(original.to_json)
      changed_route.recipient_ship = "other"
      expect_raises(Tinrelay::Unauthorized, /authentication failed/) do
        api.store.prepare(changed_route)
      end

      changed_ciphertext = Tinrelay::SignedRelayEnvelope.from_json(original.to_json)
      changed_ciphertext.ciphertext = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.random(64)
      )
      expect_raises(Tinrelay::Unauthorized, /authentication failed/) do
        api.store.prepare(changed_ciphertext)
      end
    end
  end

  it "rejects invalid or mismatched signed plaintext without transmission spooling" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))

      invalid_cases = [] of Tinrelay::SignedRelayEnvelope

      changed_body = TinrelayAuthorshipSpec.capture(beta, origin, "signed words")
      body = TinrelayAuthorshipSpec.open(changed_body, alpha)
      body.body = "changed words"
      invalid_cases << TinrelayAuthorshipSpec.reseal(
        changed_body, body, beta, alpha, resign_inner: false
      )

      changed_context = TinrelayAuthorshipSpec.capture(beta, origin, "signed context")
      context = TinrelayAuthorshipSpec.open(changed_context, alpha)
      context.to_label = "alerts"
      invalid_cases << TinrelayAuthorshipSpec.reseal(
        changed_context, context, beta, alpha, resign_inner: false
      )

      {
        "transmission id" => ->(inner : Tinrelay::SignedTransmission) do
          inner.transmission_id = Tinrelay::Ids.uuid
        end,
        "recipient" => ->(inner : Tinrelay::SignedTransmission) do
          inner.recipient_ship = "other"
        end,
        "generation" => ->(inner : Tinrelay::SignedTransmission) do
          inner.recipient_encryption_generation += 1
        end,
      }.each do |label, mutate|
        envelope = TinrelayAuthorshipSpec.capture(beta, origin, "mismatch #{label}")
        inner = TinrelayAuthorshipSpec.open(envelope, alpha)
        mutate.call(inner)
        invalid_cases << TinrelayAuthorshipSpec.reseal(
          envelope, inner, beta, alpha, resign_inner: true
        )
      end

      invalid_cases.each do |envelope|
        api.store.accept(envelope)
        event = alpha.radio_wait(spool, hold_seconds: 0)
        event.kind.should eq("rejected_transmission")
        spool.get(event.local_id)
          .should be_a(Tinrelay::RejectedTransmissionSpoolRecord)
        spool.routed(event.local_id)
      end
      spool.list.none? { |record| record.kind == "transmission" }.should be_true
    end
  end

  it "keeps signed plaintext verifiable after relay erasure and receive-key retirement" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))
      delta = TinrelaySpec.admit_contact(
        root, origin, "delta", beta
      )
      beta_spool = Tinrelay::Spool.new(File.join(root, "beta-inbox"))
      delta.send("steward@beta", "establish delta")
      beta_established = beta.radio_wait(
        beta_spool, hold_seconds: 0
      )
      beta_spool.routed(beta_established.local_id)

      gamma = TinrelaySpec.admit_contact(
        root, origin, "gamma", alpha
      )
      gamma.send("steward@alpha", "establish gamma")
      gamma_established = alpha.radio_wait(spool, hold_seconds: 0)
      spool.routed(gamma_established.local_id)

      beta.send("steward@alpha", "establish generation one", "caller")
      first = alpha.radio_wait(spool, hold_seconds: 0)
      spool.routed(first.local_id)

      beta.rotate_owner.should eq(2)
      beta.close_contact("delta").should eq(2)
      retune_events = Channel(Tinrelay::RadioEvent).new
      spawn { retune_events.send(alpha.radio_wait(spool, hold_seconds: 1)) }
      TinrelaySpec.eventually do
        api.database.db.query_one(
          "SELECT state FROM relationships WHERE ship_a = 'alpha' AND ship_b = 'beta'",
          as: String
        ) == "active"
      end
      sent = beta.send("steward@alpha", "durable provenance", "caller")
      event = TinrelaySpec.receive(retune_events)

      api.database.db.query_one(
        "SELECT ciphertext IS NULL, signature IS NULL FROM transmissions WHERE id = ?",
        sent.transmission_id, as: {Int64, Int64}
      ).should eq({1_i64, 1_i64})
      alpha.close_contact("gamma").should eq(2)
      deadline = Time.utc.to_unix + Tinrelay::FALLBACK_LIFETIME_SECONDS + 1
      alpha.keyring.prune_retired_radios!(deadline).should be_true
      alpha.keyring.data.radios.map(&.generation).should eq([2])

      record = spool.get(event.local_id).as(Tinrelay::TransmissionSpoolRecord)
      record.signed_transmission.body.should eq("durable provenance")
      record.sender_radio_certificate.generation.should eq(2)
      record.sender_owner_chain.map(&.generation).should eq([1, 2])
      record.sender_owner_chain.last.public_key.should eq(beta.keyring.data.owner_public_key)
      pattern = File.join(spool.root, "**", "#{record.local_id}.json")
      local_path = Dir.glob(Path.new(pattern).to_posix).first
      local_json = File.read(local_path)
      local_json.scan("durable provenance").size.should eq(1)
      local_json.should_not contain(sent.ciphertext)
    end
  end
end
