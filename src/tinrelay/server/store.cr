module Tinrelay
  class Store
    CLEANUP_BATCH_SIZE = 256
    AUTH_SKEW_SECONDS  = 5 * 60

    getter database : Database
    getter permanent_metadata_limit : Int64

    def initialize(@database,
                   @permanent_metadata_limit = DEFAULT_PERMANENT_METADATA_LIMIT)
      unless permanent_metadata_limit.in?(1_i64..MAX_PERMANENT_METADATA_LIMIT)
        raise Invalid.new(
          "permanent metadata limit must be between 1 and " +
          MAX_PERMANENT_METADATA_LIMIT.to_s
        )
      end
      # WAL keeps reads concurrent, but a deferred read transaction cannot
      # become a writer after another connection commits. Admit one writer
      # before any Store transaction that may mutate state.
      @write_mutex = Mutex.new
      @claim_commit_mutex = Mutex.new
    end

    private def write_transaction(& : DB::Transaction -> T) : T? forall T
      @write_mutex.synchronize do
        database.db.transaction { |transaction| yield transaction }
      end
    end

    def metrics_snapshot(now : Int64 = Time.utc.to_unix)
      database.db.transaction do |transaction|
        connection = transaction.connection
        ships = %w[active frozen revoked].to_h { |state| {state, 0_i64} }
        relationships = %w[active transitioning].to_h { |state| {state, 0_i64} }
        metadata_used = permanent_metadata_usage(connection)
        connection.query("SELECT state, COUNT(*) FROM ships GROUP BY state") do |rows|
          rows.each do
            state, count = rows.read(String, Int64)
            ships[state] = count
          end
        end
        connection.query("SELECT state, COUNT(*) FROM relationships GROUP BY state") do |rows|
          rows.each do
            state, count = rows.read(String, Int64)
            relationships[state] = count
          end
        end
        {
          ships:                ships,
          relationships:        relationships,
          queued_transmissions: connection.scalar(
            "SELECT COUNT(*) FROM transmissions WHERE state = 'pending' AND expires_at > ?",
            now
          ).as(Int64),
          queued_hails: connection.scalar(
            "SELECT COUNT(*) FROM hails WHERE collected_at IS NULL " +
            "AND allowed_at IS NULL AND expires_at > ?", now
          ).as(Int64),
          oldest_transmission_age: connection.scalar(
            "SELECT MAX(0, COALESCE(? - MIN(accepted_at), 0)) FROM transmissions " +
            "WHERE state = 'pending' AND expires_at > ?", now, now
          ).as(Int64),
          oldest_hail_age: connection.scalar(
            "SELECT MAX(0, COALESCE(? - MIN(created_at), 0)) FROM hails " +
            "WHERE collected_at IS NULL AND allowed_at IS NULL AND expires_at > ?", now, now
          ).as(Int64),
          ciphertext_bytes: connection.scalar(
            "SELECT COALESCE(SUM(LENGTH(ciphertext)), 0) FROM transmissions " +
            "WHERE state = 'pending'"
          ).as(Int64),
          sqlite_files_bytes: database.files_bytes,
          metadata_used:      metadata_used,
          metadata_limit:     permanent_metadata_limit,
          metadata_headroom:  Math.max(permanent_metadata_limit - metadata_used, 0_i64),
        }
      end.not_nil!
    end

    def wait_once(request : RadioWaitRequest,
                  now : Int64 = Time.utc.to_unix) : RadioWaitResponse
      unless request.hold_seconds.in?(0..RADIO_WAIT_HOLD_SECONDS)
        raise Invalid.new(
          "wait hold must be between 0 and #{RADIO_WAIT_HOLD_SECONDS} seconds"
        )
      end
      database.db.transaction do |transaction|
        connection = transaction.connection
        verify_radio_action(connection, request.auth, "radio.wait", request.payload, now)
        updates = contact_updates(
          connection, request.auth.ship, request.known_contact_generations, now
        )
        next RadioWaitResponse.new(contact_updates: updates) unless updates.empty?
        envelope = pending_envelope(connection, request.auth.ship, now)
        next RadioWaitResponse.new(envelope: envelope) if envelope
        hail = pending_hail(
          connection, request.auth.ship, request.known_contact_generations, now
        )
        RadioWaitResponse.new(hail: hail)
      end.not_nil!
    end

    def cleanup(now : Int64 = Time.utc.to_unix)
      write_transaction do |transaction|
        connection = transaction.connection
        connection.exec(
          "DELETE FROM registration_events WHERE accepted_at <= ?",
          now - REGISTRATION_DAY_SECONDS
        )
        transmission_rowids = [] of Int64
        expired = 0_i64
        %w[pending collected withdrawn expired].each do |state|
          remaining = CLEANUP_BATCH_SIZE - transmission_rowids.size
          break if remaining == 0
          selected = connection.query_all(
            <<-SQL, state, now, remaining, as: Int64
                SELECT rowid
                  FROM transmissions
                 WHERE state = ? AND expires_at <= ?
                 ORDER BY expires_at, rowid
                 LIMIT ?
              SQL
          )
          expired = selected.size.to_i64 if state == "pending"
          transmission_rowids.concat(selected)
        end
        deleted = if transmission_rowids.empty?
                    0_i64
                  else
                    placeholders = Array.new(transmission_rowids.size, "?").join(',')
                    connection.exec(
                      "DELETE FROM transmissions WHERE rowid IN (#{placeholders})",
                      args: transmission_rowids
                    ).rows_affected
                  end
        hails_deleted = connection.exec(
          "DELETE FROM hails WHERE expires_at <= ?", now
        ).rows_affected
        relationships_deleted = connection.exec(
          "DELETE FROM relationships WHERE state = 'transitioning' AND transition_until <= ?",
          now
        ).rows_affected
        transitions_deleted = connection.exec(
          "DELETE FROM relationship_transitions WHERE expires_at <= ?", now
        ).rows_affected
        {
          expired: expired, deleted: deleted,
          hails_deleted: hails_deleted,
          relationships_deleted: relationships_deleted,
          transitions_deleted: transitions_deleted,
        }
      end.not_nil!
    end

    private def radio_key(connection : DB::Connection, ship : String,
                          generation : Int32) : Tuple(Bytes, Bytes, String)
      radio_key_row(connection, ship, generation) ||
        raise Unauthorized.new("ship radio key is not registered")
    end

    private def radio_key_row(connection : DB::Connection, ship : String,
                              generation : Int32) : Tuple(Bytes, Bytes, String)?
      connection.query_one?(
        "SELECT signing_public_key, encryption_public_key, state " +
        "FROM ship_radio_keys WHERE ship = ? AND generation = ?",
        ship, generation, as: {Bytes, Bytes, String}
      )
    end

    private def owner_key(connection : DB::Connection, ship : String,
                          generation : Int32) : Bytes
      connection.query_one?(
        "SELECT public_key FROM ship_owner_keys " +
        "WHERE ship = ? AND generation = ? AND state = 'active'",
        ship, generation, as: Bytes
      ) || raise Unauthorized.new("ship owner key is not active")
    end

    private def verify_radio_action(connection : DB::Connection, auth : RadioAuth,
                                    action : String, payload : Bytes,
                                    now : Int64) : Nil
      unauthenticated! unless Names::SHIP.matches?(auth.ship)
      unauthenticated! unless (auth.timestamp - now).abs <= AUTH_SKEW_SECONDS
      signature = decode_auth_signature(auth.signature)
      key = authenticate_radio_signature(
        connection, auth.ship, auth.radio_generation,
        auth.signing_bytes(action, payload), signature
      )
      raise Unavailable.new("ship radio is not active") unless key[2] == "active"
    end

    private def verify_owner_action(connection : DB::Connection, auth : OwnerAuth,
                                    action : String, payload : Bytes,
                                    now : Int64) : Nil
      unauthenticated! unless Names::SHIP.matches?(auth.ship)
      unauthenticated! unless (auth.timestamp - now).abs <= AUTH_SKEW_SECONDS
      signature = decode_auth_signature(auth.signature)
      key = connection.query_one?(
        "SELECT public_key, state FROM ship_owner_keys WHERE ship = ? AND generation = ?",
        auth.ship, auth.owner_generation, as: {Bytes, String}
      )
      verification_key = key.try(&.[0]) || dummy_signing_public_key
      unauthenticated! unless Crypto.verify(
                                auth.signing_bytes(action, payload), signature, verification_key
                              ) && key
      raise Unavailable.new("ship owner key is not active") unless key.not_nil![1] == "active"
      current = connection.query_one?(
        "SELECT admin_generation, state FROM ships WHERE name = ?", auth.ship,
        as: {Int64, String}
      ) || unauthenticated!
      raise Unavailable.new("ship is revoked") if current[1] == "revoked"
      unless auth.admin_generation == current[0] + 1
        raise Conflict.new("admin generation must advance by one")
      end
    end

    private def authenticate_radio_signature(
      connection : DB::Connection,
      ship : String,
      generation : Int32,
      signed_bytes : Bytes,
      signature : Bytes,
    ) : Tuple(Bytes, Bytes, String)
      key = radio_key_row(connection, ship, generation)
      verification_key = key.try(&.[0]) || dummy_signing_public_key
      unauthenticated! unless Crypto.verify(
                                signed_bytes, signature, verification_key
                              ) && key
      key.not_nil!
    end

    private def verify_active_sender(connection : DB::Connection, ship : String,
                                     generation : Int32, signed_bytes : Bytes,
                                     signature : Bytes) : Nil
      sender = authenticate_radio_signature(
        connection, ship, generation, signed_bytes, signature
      )
      raise Unavailable.new("sender radio is not active") unless sender[2] == "active"
      sender_state = connection.query_one?(
        "SELECT state FROM ships WHERE name = ?", ship, as: String
      ) || raise Unauthorized.new("sender ship is not registered")
      raise Unavailable.new("sender ship is not active") unless sender_state == "active"
    end

    private def decode_auth_signature(encoded : String) : Bytes
      signature = Crypto.unb64(encoded, "authentication signature")
      unauthenticated! unless signature.size == Crypto::SIGNATURE_BYTES
      signature
    rescue Invalid
      unauthenticated!
    end

    private def dummy_signing_public_key : Bytes
      @@dummy_signing_public_key ||= Crypto.signing_keypair(
        Bytes.new(Crypto::SIGN_SEED_BYTES, 0_u8)
      ).public_key
    end

    private def unauthenticated! : NoReturn
      raise Unauthorized.new("authentication failed")
    end

    private def require_uuid!(value : String, label : String) : Nil
      raise Invalid.new("invalid #{label}") unless Ids::PROTOCOL_UUID.matches?(value)
    end
  end
end
