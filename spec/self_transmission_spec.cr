require "./spec_helper"

class SelfTransmissionCaptureRemote < Tinrelay::Remote
  getter envelope : Tinrelay::SignedRelayEnvelope?

  def post(path : String, body : String) : String
    if path == "/v1/transmissions"
      @envelope = Tinrelay::SignedRelayEnvelope.from_json(body)
      %({"state":"accepted"})
    else
      super
    end
  end
end

module TinrelaySelfTransmissionSpec
  def self.submit(origin : String, envelope : Tinrelay::SignedRelayEnvelope) : Tuple(Int32, String)
    headers = HTTP::Headers{
      "Content-Type"        => "application/json",
      "X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s,
    }
    response = HTTP::Client.post(
      "#{origin}/v1/transmissions", headers, envelope.to_json
    )
    {response.status_code, response.body}
  end

  def self.resign(client : Tinrelay::Client,
                  envelope : Tinrelay::SignedRelayEnvelope) : Nil
    radio = client.keyring.data.radio!
    envelope.signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        envelope.signing_bytes,
        Tinrelay::Crypto.unb64(radio.signing.secret_key)
      )
    )
  end
end

describe "ordinary self-transmission" do
  it "routes an empty local part as ordinary ship-general attention" do
    TinrelaySpec.with_server do |root, origin, _api|
      ship = Tinrelay::Client.join(
        File.join(root, "harbor.keyring"), origin, "harbor")
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))

      ship.send("@harbor", "general call")
      event = ship.radio_wait(spool, hold_seconds: 0)

      event.name.should eq("")
      mapping = {"" => "ship-task", "*" => "fallback-task"}
      (mapping[event.name.not_nil!]? || mapping["*"]).should eq("ship-task")
      JSON.parse(event.wrapper.lines[1])["attention_label"].as_s.should eq("")
      spool.get(event.kind, event.source_id).as(Tinrelay::TransmissionSpoolRecord)
        .signed_transmission.to_label.should eq("")
    end
  end

  it "uses the direct repeater path, ordinary pointer routing, and no relationship" do
    TinrelaySpec.with_server do |root, origin, api|
      ship = Tinrelay::Client.join(
        File.join(root, "harbor.keyring"), origin, "harbor")
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))

      ship.keyring.data.contacts.should be_empty
      api.database.db.scalar("SELECT COUNT(*) FROM relationships").as(Int64).should eq(0)

      delivered = Channel(Tinrelay::RadioEvent).new(1)
      spawn { delivered.send(ship.radio_wait(spool, hold_seconds: 5)) }
      TinrelaySpec.eventually { api.handoffs.waiting?("harbor") }

      envelope = ship.send("steward@harbor", "radio proof", "caller")
      event = TinrelaySpec.receive(delivered)

      envelope.sender_ship.should eq("harbor")
      envelope.recipient_ship.should eq("harbor")
      envelope.submission_evidence[:sender_ship].should eq("harbor")
      envelope.submission_evidence[:recipient_ship].should eq("harbor")
      event.kind.should eq("transmission")
      event.name.should eq("steward")
      event.wrapper.should eq(
        "TINRELAY LOCAL POINTER\n" + {
          contract:        "tinrelay-local-pointer-v2",
          kind:            "transmission",
          transmission_id: event.source_id,
          local_ship:      "harbor",
          sender_ship:     "harbor",
          attention_label: "steward",
        }.to_json
      )

      record = spool.get(event.kind, event.source_id).as(Tinrelay::TransmissionSpoolRecord)
      record.sender_ship.should eq("harbor")
      record.recipient_ship.should eq("harbor")
      record.signed_transmission.body.should eq("radio proof")
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", envelope.transmission_id
      ).as(Int64).should eq(0)

      spool.next_unrouted.not_nil!.source_id.should eq(event.source_id)
      spool.routed(event.kind, event.source_id)
      spool.next_unrouted.should be_nil
      spool.get(event.kind, event.source_id).as(Tinrelay::TransmissionSpoolRecord)
        .signed_transmission.body.should eq("radio proof")
      ship.keyring.data.contacts.should be_empty
      api.database.db.scalar("SELECT COUNT(*) FROM relationships").as(Int64).should eq(0)
    end
  end

  it "uses durable fallback without a waiter and after an interrupted handoff" do
    TinrelaySpec.with_server do |root, origin, api|
      ship = Tinrelay::Client.join(
        File.join(root, "harbor.keyring"), origin, "harbor")
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))

      absent = ship.send("steward@harbor", "waiter absent")
      api.database.db.query_one(
        "SELECT state, ciphertext IS NOT NULL FROM transmissions WHERE id = ?",
        absent.transmission_id, as: {String, Int64}
      ).should eq({"pending", 1_i64})

      absent_event = ship.radio_wait(spool, hold_seconds: 0)
      spool.get(absent_event.kind, absent_event.source_id).as(Tinrelay::TransmissionSpoolRecord)
        .signed_transmission.body.should eq("waiter absent")
      api.database.db.query_one(
        "SELECT state, ciphertext IS NULL FROM transmissions WHERE id = ?",
        absent.transmission_id, as: {String, Int64}
      ).should eq({"collected", 1_i64})
      spool.routed(absent_event.kind, absent_event.source_id)

      capture = SelfTransmissionCaptureRemote.new(origin)
      Tinrelay::Client.new(ship.keyring, capture)
        .send("steward@harbor", "handoff interrupted")
      interrupted = capture.envelope.not_nil!
      wait_result = Channel(String).new(1)
      request = TinrelaySpec.radio_wait_request(ship, 5)
      spawn { wait_result.send(ship.remote.post("/v1/radio/wait", request.to_json)) }
      TinrelaySpec.eventually { api.handoffs.waiting?("harbor") }

      accepted = Channel(String).new(1)
      spawn do
        accepted.send(ship.remote.post("/v1/transmissions", interrupted.to_json))
      end
      offered = Tinrelay::RadioWaitResponse.from_json(
        TinrelaySpec.receive(wait_result)
      ).envelope.not_nil!
      offered.transmission_id.should eq(interrupted.transmission_id)

      # The simulated radio disappears before durable local spool acknowledgement.
      JSON.parse(TinrelaySpec.receive(accepted))["state"].as_s.should eq("accepted")
      api.database.db.query_one(
        "SELECT state, ciphertext IS NOT NULL FROM transmissions WHERE id = ?",
        interrupted.transmission_id, as: {String, Int64}
      ).should eq({"pending", 1_i64})
      ship.keyring.data.contacts.should be_empty
      api.database.db.scalar("SELECT COUNT(*) FROM relationships").as(Int64).should eq(0)
    end
  end

  it "keeps the exception exact, relationship-gated, and authentication-blind" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit(root, origin, "beta")
      capture = SelfTransmissionCaptureRemote.new(origin)
      Tinrelay::Client.new(beta.keyring, capture)
        .send("steward@beta", "sealed for beta")
      self_envelope = capture.envelope.not_nil!

      self_response = TinrelaySelfTransmissionSpec.submit(origin, self_envelope)
      self_response.should eq({202, %({"state":"accepted"})})
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?",
        self_envelope.transmission_id
      ).as(Int64).should eq(1)

      unrelated = Tinrelay::SignedRelayEnvelope.from_json(self_envelope.to_json)
      unrelated.transmission_id = Tinrelay::Ids.uuid
      unrelated.recipient_ship = "alpha"
      TinrelaySelfTransmissionSpec.resign(beta, unrelated)
      TinrelaySelfTransmissionSpec.submit(origin, unrelated)
        .should eq({202, %({"state":"accepted"})})
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", unrelated.transmission_id
      ).as(Int64).should eq(0)

      forged_self = Tinrelay::SignedRelayEnvelope.from_json(self_envelope.to_json)
      forged_self.transmission_id = Tinrelay::Ids.uuid
      forged_self.sender_ship = "alpha"
      forged_self.recipient_ship = "alpha"
      TinrelaySelfTransmissionSpec.resign(beta, forged_self)

      forged_other = Tinrelay::SignedRelayEnvelope.from_json(forged_self.to_json)
      forged_other.transmission_id = Tinrelay::Ids.uuid
      forged_other.recipient_ship = "beta"
      TinrelaySelfTransmissionSpec.resign(beta, forged_other)

      self_failure = TinrelaySelfTransmissionSpec.submit(origin, forged_self)
      other_failure = TinrelaySelfTransmissionSpec.submit(origin, forged_other)
      self_failure.should eq(other_failure)
      self_failure[0].should eq(401)
      alpha.keyring.data.contacts.should be_empty
      beta.keyring.data.contacts.should be_empty
      api.database.db.scalar("SELECT COUNT(*) FROM relationships").as(Int64).should eq(0)
    end
  end
end
