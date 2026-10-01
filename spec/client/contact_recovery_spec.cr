require "../spec_helper"

describe "receive after contact-pin loss" do
  it "preserves queued ciphertext and restores trust through a fresh verified hail" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit_contact(root, origin, "beta", alpha)
      sent = beta.send("steward@alpha", "recoverable queued words", "caller")
      queued = api.database.db.query_one(
        "SELECT ciphertext, signature FROM transmissions WHERE id = ?",
        sent.transmission_id, as: {Bytes, Bytes}
      )
      alpha.keyring.data.contacts.clear
      alpha.keyring.save
      spool = Tinrelay::Spool.new(File.join(root, "recovered-inbox"))

      2.times do
        restored = Tinrelay::Client.new(Tinrelay::Keyring.load(alpha.keyring.path))
        expect_raises(Tinrelay::ContactPinRequired) do
          restored.radio_poll(spool)
        end
        spool.list.should be_empty
        restored.keyring.data.contacts.should be_empty
        api.database.db.query_one(
          "SELECT state, ciphertext, signature FROM transmissions WHERE id = ?",
          sent.transmission_id, as: {String, Bytes, Bytes}
        ).should eq({"pending", queued[0], queued[1]})
      end

      # Preserve the existing recently-allowed hail duplicate window. Once it
      # expires, a fresh recovery hail must be reachable without consuming words.
      api.database.db.exec(
        "UPDATE hails SET expires_at = ? WHERE sender_ship = 'beta' AND recipient_ship = 'alpha'",
        Time.utc.to_unix - 1
      )
      hail = beta.hail("alpha")
      api.database.db.scalar(
        "SELECT COUNT(*) FROM hails WHERE id = ?", hail.hail_id
      ).as(Int64).should eq(1_i64)
      # An older local pointer must not force us to erase evidence just to
      # collect the recovery hail. The existing collector bypasses local work.
      now = Time.utc.to_unix
      prior = spool.store_rejection(
        Tinrelay::SignedRelayEnvelope.new(
          Tinrelay::Ids.uuid, "unknown", 1, "alpha", 1, now, now + 3600,
          Tinrelay::Crypto.b64(Tinrelay::Crypto.random(64))
        ), "unusable_envelope"
      )
      restored = Tinrelay::Client.new(Tinrelay::Keyring.load(alpha.keyring.path))
      event = restored.radio_collect(spool, hold_seconds: 0)
      event.kind.should eq("hail")
      event.source_id.should eq(hail.hail_id)
      restored.keyring.data.contacts.should be_empty
      api.database.db.query_one(
        "SELECT state, ciphertext FROM transmissions WHERE id = ?",
        sent.transmission_id, as: {String, Bytes}
      ).should eq({"pending", queued[0]})
      restored.allow_contact(event.source_id, spool)
      spool.routed(event.kind, event.source_id)

      received = restored.radio_collect(spool, hold_seconds: 0)
      received.kind.should eq("transmission")
      record = spool.get(received.kind, received.source_id).as(Tinrelay::TransmissionSpoolRecord)
      record.transmission_id.should eq(sent.transmission_id)
      record.signed_transmission.body.should eq("recoverable queued words")
      record.signed_transmission.from_label.should eq("caller")
      spool.get(prior.kind, prior.source_id).routed.should be_false
      api.database.db.query_one(
        "SELECT state, ciphertext IS NULL FROM transmissions WHERE id = ?",
        sent.transmission_id, as: {String, Int64}
      ).should eq({"collected", 1_i64})
    end
  end

  it "leaves an unacknowledged direct offer in fallback when its local pin is missing" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit_contact(root, origin, "beta", alpha)
      alpha.keyring.data.contacts.clear
      alpha.keyring.save
      spool = Tinrelay::Spool.new(File.join(root, "recovered-inbox"))
      failure = Channel(Tinrelay::ContactPinRequired?).new(1)
      spawn do
        result = begin
          alpha.radio_wait(spool, hold_seconds: 5)
          nil
        rescue error : Tinrelay::ContactPinRequired
          error
        end
        failure.send(result)
      end
      TinrelaySpec.eventually { api.handoffs.waiting?("alpha") }

      sent = beta.send("steward@alpha", "preserved direct offer")

      TinrelaySpec.receive(failure).should be_a(Tinrelay::ContactPinRequired)
      spool.list.should be_empty
      api.database.db.query_one(
        "SELECT state, ciphertext IS NOT NULL FROM transmissions WHERE id = ?",
        sent.transmission_id, as: {String, Int64}
      ).should eq({"pending", 1_i64})
    end
  end
end
