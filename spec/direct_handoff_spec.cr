require "./spec_helper"

describe "direct radio handoff" do
  it "accepts at durable destination spool acknowledgement without waiting for pointer routing" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )

      capture = TinrelaySpec::CaptureRemote.new(origin)
      composer = Tinrelay::Client.new(beta.keyring, capture)
      composer.send("steward@alpha", "direct payload", "caller")
      envelope = capture.captured.first

      wait_request = TinrelaySpec.radio_wait_request(alpha, 5)
      wait_result = Channel(String).new(1)
      spawn { wait_result.send(alpha.remote.post("/v1/radio/wait", wait_request.to_json)) }
      TinrelaySpec.eventually { api.handoffs.waiting?("alpha") }

      sender_result = Channel({String, Time::Instant}).new(1)
      spawn do
        result = beta.remote.post("/v1/transmissions", envelope.to_json)
        sender_result.send({result, Time.instant})
      end
      offered = Tinrelay::RadioWaitResponse.from_json(
        TinrelaySpec.receive(wait_result)
      ).envelope.not_nil!

      # A parked wait receives the envelope while SQLite still owns no transmission row.
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", envelope.transmission_id
      ).as(Int64).should eq(0)

      select
      when sender_result.receive
        fail "sender was accepted before destination spool acknowledgement"
      when timeout(50.milliseconds)
      end

      spool = Tinrelay::Spool.new(File.join(root, "inbox"))
      radio = alpha.keyring.data.radio!(offered.recipient_encryption_generation)
      plaintext = Tinrelay::Crypto.open(
        Tinrelay::Crypto.unb64(offered.ciphertext),
        Tinrelay::Crypto.unb64(radio.encryption.public_key),
        Tinrelay::Crypto.unb64(radio.encryption.secret_key)
      )
      local_record = spool.store_transmission(
        offered, Tinrelay::SignedTransmission.from_json(String.new(plaintext)),
        beta.keyring.data.radio!(offered.sender_signing_generation).certificate,
        beta.keyring.data.owner_public_key
      )
      spooled_at = Time.instant
      ack = Tinrelay::TransmissionAck.new(
        offered.transmission_id,
        TinrelaySpec.radio_auth(
          alpha, "transmission.ack", Tinrelay::Canonical.fields(offered.transmission_id)
        )
      )
      alpha.remote.post("/v1/transmissions/ack", ack.to_json)

      accepted, accepted_at = TinrelaySpec.receive(sender_result)
      JSON.parse(accepted)["state"].as_s.should eq("accepted")
      (accepted_at - spooled_at).should be < 2.seconds
      spool.next_unrouted.not_nil!.source_id.should eq(local_record.source_id)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", envelope.transmission_id
      ).as(Int64).should eq(0)

      # Loss of the first ack response cannot strand the already-durable local pointer.
      alpha.remote.post("/v1/transmissions/ack", ack.to_json)
      spool.next_unrouted.not_nil!.source_id.should eq(local_record.source_id)
    end
  end

  it "persists when no wait exists and after an unacknowledged direct offer" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      capture = TinrelaySpec::CaptureRemote.new(origin)
      composer = Tinrelay::Client.new(beta.keyring, capture)

      composer.send("steward@alpha", "no waiter", "caller")
      absent = capture.captured.first
      response = beta.remote.post("/v1/transmissions", absent.to_json)
      JSON.parse(response)["state"].as_s.should eq("accepted")
      api.database.db.query_one(
        "SELECT state, ciphertext IS NOT NULL FROM transmissions WHERE id = ?",
        absent.transmission_id, as: {String, Int64}
      ).should eq({"pending", 1_i64})
      absent_ack = Tinrelay::TransmissionAck.new(
        absent.transmission_id,
        TinrelaySpec.radio_auth(
          alpha, "transmission.ack", Tinrelay::Canonical.fields(absent.transmission_id)
        )
      )
      api.store.acknowledge(absent_ack)

      capture = TinrelaySpec::CaptureRemote.new(origin)
      composer = Tinrelay::Client.new(beta.keyring, capture)
      composer.send("steward@alpha", "waiter vanished", "caller")
      interrupted = capture.captured.first
      wait_request = TinrelaySpec.radio_wait_request(alpha, 5)
      offered = Channel(String).new(1)
      spawn { offered.send(alpha.remote.post("/v1/radio/wait", wait_request.to_json)) }
      TinrelaySpec.eventually { api.handoffs.waiting?("alpha") }
      accepted = Channel(String).new(1)
      spawn { accepted.send(beta.remote.post("/v1/transmissions", interrupted.to_json)) }
      Tinrelay::RadioWaitResponse.from_json(
        TinrelaySpec.receive(offered)
      ).envelope.not_nil!.transmission_id.should eq(interrupted.transmission_id)

      # Simulate a destination that disconnects after receiving but before its spool ack.
      JSON.parse(TinrelaySpec.receive(accepted))["state"].as_s.should eq("accepted")
      api.database.db.query_one(
        "SELECT state, ciphertext IS NOT NULL FROM transmissions WHERE id = ?",
        interrupted.transmission_id, as: {String, Int64}
      ).should eq({"pending", 1_i64})

      api.close
      restarted = Tinrelay::API.new(api.config)
      begin
        restarted.database.db.query_one(
          "SELECT state, ciphertext IS NOT NULL FROM transmissions WHERE id = ?",
          interrupted.transmission_id, as: {String, Int64}
        ).should eq({"pending", 1_i64})
      ensure
        restarted.close
      end
    end
  end

  it "does not hand new-generation traffic to a parked old radio" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      gamma = TinrelaySpec.admit_contact(
        root, origin, "gamma", alpha
      )

      old_request = TinrelaySpec.radio_wait_request(alpha, 5)
      old_result = Channel(Symbol).new(1)
      spawn do
        begin
          alpha.remote.post("/v1/radio/wait", old_request.to_json)
          old_result.send(:returned)
        rescue Tinrelay::Unavailable
          old_result.send(:unavailable)
        end
      end
      TinrelaySpec.eventually { api.handoffs.waiting?("alpha") }

      alpha.close_contact(beta.keyring.data.ship).should eq(2)
      TinrelaySpec.receive(old_result).should eq(:unavailable)
      TinrelaySpec.eventually { !api.handoffs.waiting?("alpha") }

      gamma_spool = Tinrelay::Spool.new(File.join(root, "gamma-inbox"))
      gamma_event = Channel(Tinrelay::RadioEvent).new(1)
      spawn do
        gamma_event.send(gamma.radio_wait(gamma_spool, hold_seconds: 5))
      end
      TinrelaySpec.eventually { api.handoffs.waiting?("gamma") }
      alpha.send("steward@gamma", "retune checkpoint")
      received = TinrelaySpec.receive(gamma_event)
      gamma_spool.routed(received.kind, received.source_id)
      gamma.keyring.data.contact!("alpha")
        .radio_certificate.generation.should eq(2)

      stale_waiter = api.handoffs.park("alpha", 1)
      transmission = gamma.send("steward@alpha", "new generation fallback")
      api.handoffs.wait(stale_waiter, 1.second).should eq(:changed)
      api.handoffs.release("alpha", stale_waiter)

      api.database.db.query_one(
        "SELECT state FROM transmissions WHERE id = ?",
        transmission.transmission_id, as: String
      ).should eq("pending")
      spool = Tinrelay::Spool.new(File.join(root, "alpha-inbox"))
      received = alpha.radio_wait(spool, hold_seconds: 0)
      received.kind.should eq("transmission")
      spool.get(received.kind, received.source_id).as(Tinrelay::TransmissionSpoolRecord)
        .signed_transmission.body.should eq("new generation fallback")
    end
  end
end
