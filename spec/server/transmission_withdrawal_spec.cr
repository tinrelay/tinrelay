require "../spec_helper"

module TinrelayTransmissionWithdrawalSpec
  HEADERS = HTTP::Headers{
    "Content-Type"        => "application/json",
    "X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s,
  }

  def self.envelope(sender : Tinrelay::Client, recipient : Tinrelay::Client,
                    expires_in = 3_600_i64) : Tinrelay::SignedRelayEnvelope
    sender_radio = sender.keyring.data.radio!
    recipient_radio = recipient.keyring.data.radio!
    now = Time.utc.to_unix
    transmission_id = Tinrelay::Ids.uuid
    ciphertext = Tinrelay::Crypto.random(64)
    envelope = Tinrelay::SignedRelayEnvelope.new(
      transmission_id, sender.keyring.data.ship, sender_radio.generation,
      recipient.keyring.data.ship, recipient_radio.generation,
      now, now + expires_in, Tinrelay::Crypto.b64(ciphertext)
    )
    envelope.signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        envelope.signing_bytes,
        Tinrelay::Crypto.unb64(sender_radio.signing.secret_key)
      )
    )
    envelope
  end

  def self.withdrawal(client : Tinrelay::Client, transmission_id : String,
                      now = Time.utc.to_unix) : Tinrelay::TransmissionWithdrawal
    placeholder = Tinrelay::RadioAuth.new(
      client.keyring.data.ship,
      client.keyring.data.active_radio_generation,
      now
    )
    request = Tinrelay::TransmissionWithdrawal.new(transmission_id, placeholder)
    request.auth = TinrelaySpec.radio_auth(
      client, "transmission.withdraw", request.payload, now
    )
    request
  end

  def self.post(origin : String, path : String, body : String)
    HTTP::Client.post("#{origin}#{path}", HEADERS, body)
  end

  def self.persist(api : Tinrelay::API, envelope : Tinrelay::SignedRelayEnvelope) : Nil
    api.store.accept(envelope)
    api.database.db.query_one(
      "SELECT state FROM transmissions WHERE id = ?", envelope.transmission_id,
      as: String
    ).should eq("pending")
  end

  def self.acknowledgement(client : Tinrelay::Client, transmission_id : String)
    Tinrelay::TransmissionAck.new(
      transmission_id,
      TinrelaySpec.radio_auth(
        client, "transmission.ack", Tinrelay::Canonical.fields(transmission_id)
      )
    )
  end
end

describe "blind transmission withdrawal" do
  it "erases pending ciphertext, absorbs exact replay, and expires the tombstone" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit_contact(root, origin, "beta", alpha)
      envelope = TinrelayTransmissionWithdrawalSpec.envelope(beta, alpha, 30_i64)
      TinrelayTransmissionWithdrawalSpec.persist(api, envelope)
      request = TinrelayTransmissionWithdrawalSpec.withdrawal(
        beta, envelope.transmission_id
      )

      started = Time.instant
      response = TinrelayTransmissionWithdrawalSpec.post(
        origin, "/v1/transmissions/withdraw", request.to_json
      )
      elapsed = Time.instant - started

      response.status_code.should eq(202)
      response.body.should eq(%({"state":"accepted"}))
      response.headers["Cache-Control"].should eq("no-store")
      elapsed.should be >= Tinrelay::API::ACCEPTANCE_TARGET - 25.milliseconds
      api.database.db.query_one(
        "SELECT state, ciphertext, signature FROM transmissions WHERE id = ?",
        envelope.transmission_id, as: {String, Bytes?, Bytes?}
      ).should eq({"withdrawn", nil, nil})

      replay = TinrelayTransmissionWithdrawalSpec.post(
        origin, "/v1/transmissions", envelope.to_json
      )
      replay.status_code.should eq(202)
      replay.body.should eq(response.body)
      api.database.db.query_one(
        "SELECT state, ciphertext, signature FROM transmissions WHERE id = ?",
        envelope.transmission_id, as: {String, Bytes?, Bytes?}
      ).should eq({"withdrawn", nil, nil})
      alpha.radio_poll(Tinrelay::Spool.new(File.join(root, "alpha-inbox"))).should be_nil

      metrics = HTTP::Client.get("#{origin}/metrics").body
      metrics.should contain(
        "tinrelay_transmission_withdrawals_total{outcome=\"requested\"} 1"
      )
      metrics.should contain(
        "tinrelay_transmission_withdrawals_total{outcome=\"changed\"} 1"
      )

      api.store.cleanup(envelope.expires_at + 1)
      api.database.db.query_one?(
        "SELECT id FROM transmissions WHERE id = ?", envelope.transmission_id,
        as: String
      ).should be_nil
    end
  end

  it "returns one fixed response for every authenticated opaque state" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit_contact(root, origin, "beta", alpha)
      gamma = TinrelaySpec.admit(root, origin, "gamma")

      pending = TinrelayTransmissionWithdrawalSpec.envelope(beta, alpha)
      collected = TinrelayTransmissionWithdrawalSpec.envelope(beta, alpha)
      withdrawn = TinrelayTransmissionWithdrawalSpec.envelope(beta, alpha)
      expired = TinrelayTransmissionWithdrawalSpec.envelope(beta, alpha)
      foreign = TinrelayTransmissionWithdrawalSpec.envelope(beta, alpha)
      [pending, collected, withdrawn, expired, foreign].each do |envelope|
        TinrelayTransmissionWithdrawalSpec.persist(api, envelope)
      end
      api.store.acknowledge(
        TinrelayTransmissionWithdrawalSpec.acknowledgement(
          alpha, collected.transmission_id
        )
      )
      api.store.withdraw(
        TinrelayTransmissionWithdrawalSpec.withdrawal(
          beta, withdrawn.transmission_id
        )
      )
      api.database.db.exec(
        "UPDATE transmissions SET state = 'expired', ciphertext = NULL, " +
        "signature = NULL WHERE id = ?", expired.transmission_id
      )

      cases = [
        {beta, pending.transmission_id},
        {beta, collected.transmission_id},
        {beta, withdrawn.transmission_id},
        {beta, expired.transmission_id},
        {gamma, foreign.transmission_id},
        {beta, Tinrelay::Ids.uuid},
      ]
      responses = cases.map do |client, transmission_id|
        request = TinrelayTransmissionWithdrawalSpec.withdrawal(client, transmission_id)
        started = Time.instant
        response = TinrelayTransmissionWithdrawalSpec.post(
          origin, "/v1/transmissions/withdraw", request.to_json
        )
        elapsed = Time.instant - started
        elapsed.should be >= Tinrelay::API::ACCEPTANCE_TARGET - 25.milliseconds
        {
          response.status_code,
          response.body,
          response.headers["Content-Type"],
          response.headers["Cache-Control"],
          response.headers["Content-Length"],
        }
      end

      responses.uniq.should eq([{
        202,
        %({"state":"accepted"}),
        "application/json; charset=utf-8",
        "no-store",
        %({"state":"accepted"}).bytesize.to_s,
      }])
      api.database.db.query_one(
        "SELECT state FROM transmissions WHERE id = ?", pending.transmission_id,
        as: String
      ).should eq("withdrawn")
      api.database.db.query_one(
        "SELECT state FROM transmissions WHERE id = ?", collected.transmission_id,
        as: String
      ).should eq("collected")
      api.database.db.query_one(
        "SELECT state FROM transmissions WHERE id = ?", withdrawn.transmission_id,
        as: String
      ).should eq("withdrawn")
      api.database.db.query_one(
        "SELECT state FROM transmissions WHERE id = ?", expired.transmission_id,
        as: String
      ).should eq("expired")
      api.database.db.query_one(
        "SELECT state FROM transmissions WHERE id = ?", foreign.transmission_id,
        as: String
      ).should eq("pending")
    end
  end

  it "uses the sender's current radio after rotation without consulting relationship state" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit_contact(root, origin, "beta", alpha)
      envelope = TinrelayTransmissionWithdrawalSpec.envelope(beta, alpha)
      TinrelayTransmissionWithdrawalSpec.persist(api, envelope)

      beta.close_contact(alpha.keyring.data.ship).should eq(2)
      response = TinrelayTransmissionWithdrawalSpec.post(
        origin,
        "/v1/transmissions/withdraw",
        TinrelayTransmissionWithdrawalSpec.withdrawal(
          beta, envelope.transmission_id
        ).to_json
      )

      response.status_code.should eq(202)
      api.database.db.query_one(
        "SELECT state, ciphertext, signature FROM transmissions WHERE id = ?",
        envelope.transmission_id, as: {String, Bytes?, Bytes?}
      ).should eq({"withdrawn", nil, nil})
    end
  end

  it "treats an in-flight direct handoff as the same blind no-op as an absent row" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit_contact(root, origin, "beta", alpha)
      envelope = TinrelayTransmissionWithdrawalSpec.envelope(beta, alpha)
      prepared = api.store.prepare(envelope)
      waiter = api.handoffs.park(
        alpha.keyring.data.ship,
        alpha.keyring.data.active_radio_generation
      )
      delivered = Channel(Bool).new(1)
      spawn { delivered.send(api.handoffs.deliver(prepared, 2.seconds)) }
      offered = api.handoffs.wait(waiter, 1.second).as(Tinrelay::SignedRelayEnvelope)
      offered.transmission_id.should eq(envelope.transmission_id)

      response = TinrelayTransmissionWithdrawalSpec.post(
        origin,
        "/v1/transmissions/withdraw",
        TinrelayTransmissionWithdrawalSpec.withdrawal(
          beta, envelope.transmission_id
        ).to_json
      )
      response.status_code.should eq(202)
      response.body.should eq(%({"state":"accepted"}))
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", envelope.transmission_id
      ).should eq(0_i64)
      api.handoffs.prepared_for_ack(
        envelope.transmission_id, alpha.keyring.data.ship
      ).should_not be_nil

      api.handoffs.complete(envelope.transmission_id)
      TinrelaySpec.receive(delivered).should be_true
      api.handoffs.release(alpha.keyring.data.ship, waiter)
    end
  end

  it "rejects malformed, unauthenticated, incompatible, and rate-limited requests" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit_contact(root, origin, "beta", alpha)
      envelope = TinrelayTransmissionWithdrawalSpec.envelope(beta, alpha)
      TinrelayTransmissionWithdrawalSpec.persist(api, envelope)

      malformed = TinrelayTransmissionWithdrawalSpec.post(
        origin, "/v1/transmissions/withdraw", "{"
      )
      malformed.status_code.should eq(400)

      tampered = TinrelayTransmissionWithdrawalSpec.withdrawal(
        beta, envelope.transmission_id
      )
      tampered.auth.signature = Tinrelay::Crypto.b64(
        Bytes.new(Tinrelay::Crypto::SIGNATURE_BYTES, 0_u8)
      )
      unauthorized = TinrelayTransmissionWithdrawalSpec.post(
        origin, "/v1/transmissions/withdraw", tampered.to_json
      )
      unauthorized.status_code.should eq(401)

      incompatible_headers = TinrelayTransmissionWithdrawalSpec::HEADERS.dup
      incompatible_headers["X-Tinrelay-Protocol"] = (Tinrelay::PROTOCOL - 1).to_s
      incompatible = HTTP::Client.post(
        "#{origin}/v1/transmissions/withdraw",
        incompatible_headers,
        TinrelayTransmissionWithdrawalSpec.withdrawal(
          beta, envelope.transmission_id
        ).to_json
      )
      incompatible.status_code.should eq(426)

      now = Time.instant
      Tinrelay::TransmissionTokenBuckets::MESSAGE_CAPACITY.times do
        api.transmission_buckets.admit(
          TinrelaySpec::TEST_SOURCE_BUCKET, 0, now
        ).should be_nil
      end
      limited = TinrelayTransmissionWithdrawalSpec.post(
        origin, "/v1/transmissions/withdraw",
        TinrelayTransmissionWithdrawalSpec.withdrawal(
          beta, envelope.transmission_id
        ).to_json
      )
      limited.status_code.should eq(429)
      limited.headers["Retry-After"].to_i.should be > 0

      api.database.db.query_one(
        "SELECT state FROM transmissions WHERE id = ?", envelope.transmission_id,
        as: String
      ).should eq("pending")
      metrics = HTTP::Client.get("#{origin}/metrics").body
      metrics.should contain(
        "tinrelay_transmission_withdrawals_total{outcome=\"requested\"} 1"
      )
      metrics.should contain(
        "tinrelay_transmission_withdrawals_total{outcome=\"changed\"} 0"
      )
    end
  end

  it "serializes withdrawal with recipient collection without later redelivery" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit_contact(root, origin, "beta", alpha)
      envelope = TinrelayTransmissionWithdrawalSpec.envelope(beta, alpha)
      TinrelayTransmissionWithdrawalSpec.persist(api, envelope)
      withdrawal = TinrelayTransmissionWithdrawalSpec.withdrawal(
        beta, envelope.transmission_id
      )
      acknowledgement = TinrelayTransmissionWithdrawalSpec.acknowledgement(
        alpha, envelope.transmission_id
      )
      results = Channel(Nil).new(2)

      spawn do
        api.store.withdraw(withdrawal)
        results.send(nil)
      end
      spawn do
        api.store.acknowledge(acknowledgement)
        results.send(nil)
      end
      2.times { TinrelaySpec.receive(results) }

      api.database.db.query_one(
        "SELECT state, ciphertext, signature FROM transmissions WHERE id = ?",
        envelope.transmission_id, as: {String, Bytes?, Bytes?}
      ).tap do |row|
        %w[collected withdrawn].should contain(row[0])
        row[1].should be_nil
        row[2].should be_nil
      end
      alpha.radio_poll(Tinrelay::Spool.new(File.join(root, "alpha-inbox"))).should be_nil
    end
  end
end
