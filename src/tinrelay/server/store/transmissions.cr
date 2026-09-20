module Tinrelay
  class PreparedRelayEnvelope
    getter envelope : SignedRelayEnvelope
    getter ciphertext : Bytes
    getter signature : Bytes
    getter digest : Bytes
    getter accepted_at : Int64
    getter? stored : Bool

    def initialize(@envelope, @ciphertext, @signature, @digest, @accepted_at, @stored : Bool)
    end
  end

  class Store
    MAX_PENDING_PER_SHIP = 100
    MAX_CIPHERTEXT_BYTES = 17 * 1024
    MAX_PENDING_SECONDS  = FALLBACK_LIFETIME_SECONDS

    def prepare(envelope : SignedRelayEnvelope,
                now : Int64 = Time.utc.to_unix) : PreparedRelayEnvelope
      validate_envelope_shape!(envelope)
      ciphertext = Crypto.unb64(envelope.ciphertext, "ciphertext")
      if ciphertext.size > MAX_CIPHERTEXT_BYTES
        raise Invalid.new("ciphertext exceeds #{MAX_CIPHERTEXT_BYTES} bytes")
      end
      signature = Crypto.unb64(envelope.signature, "relay envelope signature")
      envelope_digest = Digest::SHA256.digest(envelope.signing_bytes + signature)
      stored = database.db.transaction do |transaction|
        connection = transaction.connection
        if connection.query_one?(
             "SELECT 1 FROM transmissions WHERE id = ?",
             envelope.transmission_id,
             as: Int64
           )
          stored_digest = connection.query_one(
            "SELECT envelope_digest FROM transmissions WHERE id = ?",
            envelope.transmission_id,
            as: Bytes
          )
          unless Crypto.constant_time_equal?(stored_digest, envelope_digest)
            raise Conflict.new("transmission id was reused with different contents")
          end
          next true
        end

        validate_new_envelope_time!(envelope, now)

        sender = authenticate_radio_signature(
          connection, envelope.sender_ship, envelope.sender_signing_generation,
          envelope.signing_bytes, signature
        )
        raise Unavailable.new("sender radio is not active") unless sender[2] == "active"
        sender_state = connection.query_one?(
          "SELECT state FROM ships WHERE name = ?", envelope.sender_ship, as: String
        ) || raise Unauthorized.new("sender ship is not registered")
        raise Unavailable.new("sender ship is not active") unless sender_state == "active"
        false
      end.not_nil!
      PreparedRelayEnvelope.new(
        envelope, ciphertext, signature, envelope_digest, now, stored
      )
    end

    def accept(envelope : SignedRelayEnvelope,
               now : Int64 = Time.utc.to_unix) : Nil
      prepared = prepare(envelope, now)
      persist(prepared) unless prepared.stored?
    end

    def deliverable?(prepared : PreparedRelayEnvelope) : Bool
      database.db.transaction do |transaction|
        delivery_allowed?(transaction.connection, prepared.envelope, false)
      end.not_nil!
    end

    def persist(prepared : PreparedRelayEnvelope) : Bool
      @write_mutex.synchronize do
        database.db.transaction do |transaction|
          connection = transaction.connection
          if stored_digest = connection.query_one?(
               "SELECT envelope_digest FROM transmissions WHERE id = ?",
               prepared.envelope.transmission_id, as: Bytes
             )
            unless Crypto.constant_time_equal?(stored_digest, prepared.digest)
              raise Conflict.new("transmission id was reused with different contents")
            end
            next true
          end
          next false unless delivery_allowed?(connection, prepared.envelope, true)
          insert_transmission(connection, prepared)
          true
        end
      end.not_nil!
    end

    def acknowledge(request : TransmissionAck,
                    now : Int64 = Time.utc.to_unix) : Int64?
      require_uuid!(request.transmission_id, "transmission id")
      write_transaction do |transaction|
        connection = transaction.connection
        verify_radio_action(connection, request.auth, "transmission.ack", request.payload, now)
        row = connection.query_one?(
          "SELECT recipient_ship, state, accepted_at FROM transmissions WHERE id = ?",
          request.transmission_id, as: {String, String, Int64}
        )
        # A successful direct handoff has no relay row. Treat its later ack retry,
        # an already-cleaned fallback, and an unrelated opaque ID identically.
        if row && row[0] == request.auth.ship && row[1] == "pending"
          erase_payload(connection, request.transmission_id, now)
          next Math.max(now - row[2], 0_i64)
        end
        nil
      end
    end

    def verify_ack(request : TransmissionAck,
                   now : Int64 = Time.utc.to_unix) : Nil
      require_uuid!(request.transmission_id, "transmission id")
      database.db.transaction do |transaction|
        verify_radio_action(
          transaction.connection, request.auth, "transmission.ack", request.payload, now
        )
      end
    end

    private def validate_envelope_shape!(envelope : SignedRelayEnvelope) : Nil
      unless envelope.object_version == 1 && envelope.protocol == PROTOCOL
        raise Invalid.new("unsupported signed relay envelope")
      end
      require_uuid!(envelope.transmission_id, "transmission id")
      Names.ship!(envelope.sender_ship)
      Names.ship!(envelope.recipient_ship)
    end

    private def validate_new_envelope_time!(envelope : SignedRelayEnvelope, now : Int64) : Nil
      if envelope.created_at > now + AUTH_SKEW_SECONDS
        raise Invalid.new("transmission creation time is outside the authentication window")
      end
      signed_lifetime = envelope.expires_at.to_i128 - envelope.created_at.to_i128
      unless envelope.expires_at > now &&
             envelope.expires_at <= now + MAX_PENDING_SECONDS &&
             signed_lifetime.in?(1_i128..MAX_PENDING_SECONDS.to_i128)
        raise Invalid.new("transmission expiry must be within 96 hours")
      end
    end

    private def insert_transmission(connection : DB::Connection,
                                    prepared : PreparedRelayEnvelope) : Nil
      envelope = prepared.envelope
      connection.exec(
        <<-SQL,
          INSERT INTO transmissions(
            id, sender_ship, sender_signing_generation,
            recipient_ship, recipient_encryption_generation, created_at, expires_at,
            accepted_at, state, ciphertext, signature, envelope_digest
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)
        SQL
        envelope.transmission_id, envelope.sender_ship,
        envelope.sender_signing_generation,
        envelope.recipient_ship, envelope.recipient_encryption_generation,
        envelope.created_at, envelope.expires_at, prepared.accepted_at,
        prepared.ciphertext, prepared.signature, prepared.digest
      )
    end

    private def erase_payload(connection : DB::Connection, transmission_id : String,
                              now : Int64) : Nil
      connection.exec(
        <<-SQL, transmission_id
          UPDATE transmissions
             SET state = 'collected', ciphertext = NULL,
                 signature = NULL
           WHERE id = ? AND state = 'pending'
        SQL
      )
    end

    private def delivery_allowed?(connection : DB::Connection,
                                  envelope : SignedRelayEnvelope,
                                  enforce_capacity : Bool) : Bool
      unless envelope.sender_ship == envelope.recipient_ship
        ship_a, ship_b = relationship_pair(
          envelope.sender_ship, envelope.recipient_ship
        )
        relationship = connection.query_one?(
          "SELECT 1 FROM relationships WHERE ship_a = ? AND ship_b = ? AND state = 'active'",
          ship_a, ship_b, as: Int64
        )
        return false unless relationship
      end

      recipient = begin
        radio_key(
          connection, envelope.recipient_ship,
          envelope.recipient_encryption_generation
        )
      rescue Unauthorized
        return false
      end
      return false unless recipient[2] == "active"
      destination_active = connection.query_one?(
        "SELECT 1 FROM ships WHERE name = ? AND state = 'active'",
        envelope.recipient_ship, as: Int64
      )
      return false unless destination_active
      return true unless enforce_capacity

      pending = connection.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE recipient_ship = ? AND state = 'pending'",
        envelope.recipient_ship
      ).as(Int64)
      pending < MAX_PENDING_PER_SHIP
    end

    private def pending_envelope(connection : DB::Connection, ship : String,
                                 now : Int64) : SignedRelayEnvelope?
      row = connection.query_one?(
        <<-SQL, ship, now,
          SELECT id, sender_ship, sender_signing_generation,
                 recipient_encryption_generation, created_at, expires_at, ciphertext,
                 signature
           FROM transmissions
           WHERE recipient_ship = ? AND state = 'pending' AND expires_at > ?
           ORDER BY accepted_at, rowid LIMIT 1
        SQL
        as: {String, String, Int64, Int64, Int64, Int64, Bytes, Bytes}
      )
      return nil unless row
      SignedRelayEnvelope.new(
        row[0], row[1], row[2].to_i, ship, row[3].to_i,
        row[4], row[5], Crypto.b64(row[6]), Crypto.b64(row[7])
      )
    end
  end
end
