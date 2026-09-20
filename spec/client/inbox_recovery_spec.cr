require "../spec_helper"

class InboxCaptureRemote < Tinrelay::Remote
  getter captured = [] of Tinrelay::SignedRelayEnvelope

  def post(path : String, body : String) : String
    if path == "/v1/transmissions"
      captured << Tinrelay::SignedRelayEnvelope.from_json(body)
      %({"state":"accepted"})
    else
      super
    end
  end
end

class InboxSequenceRemote < Tinrelay::Remote
  getter acknowledgements = [] of String

  def initialize(origin : String, @envelopes : Array(Tinrelay::SignedRelayEnvelope))
    super(origin)
  end

  def post(path : String, body : String) : String
    case path
    when "/v1/radio/wait"
      envelope = @envelopes.shift? || raise "test radio sequence is empty"
      Tinrelay::RadioWaitResponse.new(envelope: envelope).to_json
    when "/v1/transmissions/ack"
      acknowledgements << Tinrelay::TransmissionAck.from_json(body).transmission_id
      %({"state":"acknowledged"})
    else
      super
    end
  end
end

module TinrelayInboxSpec
  def self.changed_body(sender : Tinrelay::Client,
                        recipient : Tinrelay::Client,
                        envelope : Tinrelay::SignedRelayEnvelope,
                        body : String) : Tinrelay::SignedRelayEnvelope
    radio = sender.keyring.data.radio!(envelope.sender_signing_generation)
    transmission = Tinrelay::SignedTransmission.new(
      envelope.transmission_id, envelope.sender_ship,
      envelope.sender_signing_generation, envelope.recipient_ship,
      envelope.recipient_encryption_generation, envelope.created_at,
      "steward", body, "caller"
    )
    transmission.signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        transmission.signing_bytes,
        Tinrelay::Crypto.unb64(radio.signing.secret_key)
      )
    )
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
        Tinrelay::Crypto.unb64(radio.signing.secret_key)
      )
    )
    changed
  end

  def self.record_path(root : String, local_id : String) : String
    pattern = Path.new(File.join(root, "**", "#{local_id}.json")).to_posix
    paths = Dir.glob(pattern)
    raise "expected one immutable record, found #{paths.size}" unless paths.size == 1
    paths.first
  end
end

describe "inbox recovery transitions" do
  it "accepts an identical routed record when its pending source is already gone" do
    root = TinrelaySpec.temporary_root
    now = Time.utc.to_unix
    envelope = Tinrelay::SignedRelayEnvelope.new(
      Tinrelay::Ids.uuid, "alpha", 1, "beta", 1,
      now, now + 3600, Tinrelay::Crypto.b64(Tinrelay::Crypto.random(64))
    )
    spool = Tinrelay::Spool.new(File.join(root, "inbox"))
    record = spool.store_rejection(envelope, "invalid_envelope")
    pending = File.join(spool.pending, "#{record.local_id}.json")
    routed = File.join(spool.routed, "#{record.local_id}.json")
    begin
      File.copy(pending, routed)
      File.delete(pending)

      reconciled = spool.routed(record.local_id)
      reconciled.local_id.should eq(record.local_id)
      reconciled.routed.should be_true
    ensure
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  it "turns changed signed words under a directly delivered ID " +
     "into content-free conflict evidence" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      capture = InboxCaptureRemote.new(origin)
      Tinrelay::Client.new(beta.keyring, capture)
        .send("steward@alpha", "first signed words", "caller")
      original = capture.captured.first
      changed = TinrelayInboxSpec.changed_body(beta, alpha, original, "different signed words")
      remote = InboxSequenceRemote.new(origin, [original, changed])
      receiver = Tinrelay::Client.new(alpha.keyring, remote)
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))

      accepted = receiver.radio_wait(spool, hold_seconds: 0)
      accepted.kind.should eq("transmission")
      spool.routed(accepted.local_id)
      conflict = receiver.radio_wait(spool, hold_seconds: 0)
      conflict.kind.should eq("rejected_transmission")
      conflict.wrapper.should contain("transmission_id_conflict")
      conflict.wrapper.should_not contain("different signed words")
      conflict.wrapper.should_not contain("Authenticated sender")
      rejection = spool.get(conflict.local_id)
        .as(Tinrelay::RejectedTransmissionSpoolRecord)
      JSON.parse(spool.inspection(rejection.local_id)).as_h
        .has_key?("sender_ship").should be_false
      spool.list.count(&.kind.==("transmission")).should eq(1)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", original.transmission_id
      ).as(Int64).should eq(0)
      remote.acknowledgements.should eq([original.transmission_id, original.transmission_id])
    end
  end

  it "never attributes a sender when a relay-supplied outer signature is invalid" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      capture = InboxCaptureRemote.new(origin)
      Tinrelay::Client.new(beta.keyring, capture)
        .send("steward@alpha", "must remain sealed", "caller")
      forged = capture.captured.first
      forged.signature = Tinrelay::Crypto.b64(Tinrelay::Crypto.random(64))
      receiver = Tinrelay::Client.new(
        alpha.keyring, InboxSequenceRemote.new(origin, [forged])
      )
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))

      event = receiver.radio_wait(spool, hold_seconds: 0)
      event.kind.should eq("rejected_transmission")
      event.wrapper.should_not contain("beta")
      event.wrapper.downcase.should_not contain("authenticated sender")
      spool.get(event.local_id)
        .should be_a(Tinrelay::RejectedTransmissionSpoolRecord)
      JSON.parse(spool.inspection(event.local_id)).as_h
        .has_key?("sender_ship").should be_false
    end
  end

  it "keeps signed record bytes immutable and surfaces pending work past corrupt routed evidence" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      capture = InboxCaptureRemote.new(origin)
      composer = Tinrelay::Client.new(beta.keyring, capture)
      composer.send("steward@alpha", "old immutable evidence", "caller")
      composer.send("steward@alpha", "new pending work", "caller")
      receiver = Tinrelay::Client.new(
        alpha.keyring,
        InboxSequenceRemote.new(origin, capture.captured.dup)
      )
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))

      old_event = receiver.radio_wait(spool, hold_seconds: 0)
      pending_path = TinrelayInboxSpec.record_path(spool.root, old_event.local_id)
      original_bytes = File.read(pending_path)
      spool.routed(old_event.local_id)
      routed_path = TinrelayInboxSpec.record_path(spool.root, old_event.local_id)
      File.read(routed_path).should eq(original_bytes)
      File.write(routed_path, "corrupt routed evidence")

      new_event = receiver.radio_wait(spool, hold_seconds: 0)
      new_event.kind.should eq("transmission")
      spool.get(new_event.local_id).as(Tinrelay::TransmissionSpoolRecord)
        .signed_transmission.body.should eq("new pending work")
      inspection = spool.inspection(new_event.local_id)
      inspection.scan("new pending work").size.should eq(1)
      JSON.parse(inspection).as_h.has_key?("external_body").should be_false
    end
  end

  it "rejects a frozen ship as a new transmission sender without losing retry evidence" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      beta.ship_change("freeze")

      failure = expect_raises(Tinrelay::AcceptanceUnknown) do
        beta.send("steward@alpha", "frozen sender must not transmit")
      end
      failure.message.should eq(
        "relay acceptance is unknown for transmission #{failure.transmission_id}; " +
        "exact encrypted envelope retained; retry with: tinrelay --ship beta outbox retry " +
        "#{failure.transmission_id}: relay is unavailable"
      )
      Tinrelay::Outbox.new("#{beta.keyring.path}.outbox")
        .list.map(&.transmission_id).should eq([failure.transmission_id])
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE sender_ship = 'beta'"
      ).as(Int64).should eq(0)
    end
  end
end
