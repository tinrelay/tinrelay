module Tinrelay
  class PreparedShipClaim
    getter ship : String
    getter owner_key : Bytes
    getter certificate : ShipRadioCertificate

    def initialize(@ship, @owner_key, @certificate)
    end
  end

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
    MAX_PENDING_PER_SHIP         = 100
    MAX_HAILS_PER_DAY            =  12
    MAX_UNALLOWED_HAILS_PER_SHIP =  12
    MAX_OWNER_ROTATIONS_PER_DAY  =   4
    MAX_RADIO_RETUNES_PER_DAY    =  16
    CLEANUP_BATCH_SIZE           = 256
    ROTATION_WINDOW_SECONDS      = 24 * 60 * 60
    REGISTRATION_HOUR_SECONDS    = 60_i64 * 60
    REGISTRATION_DAY_SECONDS     = 24_i64 * REGISTRATION_HOUR_SECONDS
    MAX_CIPHERTEXT_BYTES         = 17 * 1024
    MAX_PENDING_SECONDS          = FALLBACK_LIFETIME_SECONDS
    AUTH_SKEW_SECONDS            = 5 * 60
    UUID                         = /\A
      [0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-
      [89ab][0-9a-f]{3}-[0-9a-f]{12}
    \z/x

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

    def prepare_claim(claim : ShipClaim) : PreparedShipClaim
      ship = Names.ship!(claim.ship)
      certificate = claim.radio_certificate
      raise Invalid.new("claim ship and radio certificate differ") unless certificate.ship == ship
      unless certificate.generation == 1 && certificate.owner_generation == 1
        raise Invalid.new("initial key generations must be 1")
      end
      owner_key = decode_owner_public_key(claim.owner_public_key)
      decode_radio_public_keys(certificate)
      unless Crypto.verify(
               certificate.unsigned_bytes,
               Crypto.unb64(certificate.owner_signature),
               owner_key
             )
        raise Unauthorized.new("initial radio certificate is not signed by the ship owner")
      end
      PreparedShipClaim.new(ship, owner_key, certificate)
    end

    def claim(prepared : PreparedShipClaim, source_bucket : String,
              allowances : RegistrationAllowances,
              policy_current : Proc(Bool),
              now : Int64? = nil) : Nil
      @claim_commit_mutex.synchronize do
        raise RegistrationUnavailable.new unless policy_current.call
        raise RegistrationUnavailable.new if allowances.closed?
        @write_mutex.synchronize do
          accepted_at = now || Time.utc.to_unix
          database.db.transaction do |transaction|
            connection = transaction.connection
            if connection.query_one?(
                 "SELECT 1 FROM ships WHERE name = ?", prepared.ship, as: Int64
               )
              raise Conflict.new("ship name is already claimed")
            end
            ensure_permanent_capacity!(connection, 3)
            if retry_after = registration_retry_after(
                 connection, source_bucket, allowances, accepted_at
               )
              raise RegistrationLimited.new(retry_after)
            end
            connection.exec(
              "DELETE FROM registration_events WHERE accepted_at <= ?",
              accepted_at - REGISTRATION_DAY_SECONDS
            )
            connection.exec(
              "INSERT INTO ships(name, claimed_at, state) VALUES (?, ?, 'active')",
              prepared.ship, accepted_at
            )
            connection.exec(
              <<-SQL, prepared.ship, prepared.owner_key, accepted_at
                INSERT INTO ship_owner_keys(
                  ship, generation, public_key, state, valid_from
                ) VALUES (?, 1, ?, 'active', ?)
              SQL
            )
            insert_radio_key(connection, prepared.certificate)
            connection.exec(
              "INSERT INTO registration_events(accepted_at, source_bucket) VALUES (?, ?)",
              accepted_at, source_bucket
            )
          end
        end
      end
    end

    def synchronize_claim_commit(&)
      @claim_commit_mutex.synchronize { yield }
    end

    private def write_transaction(& : DB::Transaction -> T) : T? forall T
      @write_mutex.synchronize do
        database.db.transaction { |transaction| yield transaction }
      end
    end

    def permanent_metadata_usage : Int64
      permanent_metadata_usage(database.db)
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

    def inspect_ship(request : ShipInspection,
                     now : Int64 = Time.utc.to_unix) : String
      target = Names.ship!(request.target_ship)
      requester = request.auth.ship
      visible = database.db.transaction do |transaction|
        connection = transaction.connection
        verify_radio_action(connection, request.auth, "ship.inspect", request.payload, now)
        exists = connection.query_one?(
          "SELECT 1 FROM ships WHERE name = ?", target, as: Int64
        )
        ship_a, ship_b = relationship_pair(requester, target)
        related = requester == target || connection.query_one?(
          "SELECT 1 FROM relationships WHERE ship_a = ? AND ship_b = ? AND state = 'active'",
          ship_a, ship_b, as: Int64
        )
        !!exists && !!related
      end.not_nil!
      raise NotFound.new("ship is not available to this radio") unless visible
      ship_card_json(target, now, include_admin: requester == target)
    end

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

    def prepare_hail(hail : Hail,
                     now : Int64 = Time.utc.to_unix) : Hail
      raise Invalid.new("unsupported protocol") unless hail.protocol == PROTOCOL
      require_uuid!(hail.hail_id, "hail id")
      Names.ship!(hail.sender_ship)
      Names.ship!(hail.recipient_ship)
      raise Invalid.new("a ship cannot hail itself") if hail.sender_ship == hail.recipient_ship
      unless (hail.created_at - now).abs <= AUTH_SKEW_SECONDS
        raise Invalid.new("hail creation time is outside the authentication window")
      end
      unless hail.expires_at.in?((now + 1)..(now + HAIL_LIFETIME_SECONDS))
        raise Invalid.new("hail expiry must be within one hour")
      end
      signature = Crypto.unb64(hail.signature, "hail signature")
      database.db.transaction do |transaction|
        connection = transaction.connection
        sender = authenticate_radio_signature(
          connection, hail.sender_ship, hail.sender_signing_generation,
          hail.signing_bytes, signature
        )
        raise Unavailable.new("sender radio is not active") unless sender[2] == "active"
        sender_state = connection.query_one?(
          "SELECT state FROM ships WHERE name = ?", hail.sender_ship, as: String
        ) || raise Unauthorized.new("sender ship is not registered")
        raise Unavailable.new("sender ship is not active") unless sender_state == "active"
      end
      hail
    end

    def persist_hail(hail : Hail,
                     now : Int64 = Time.utc.to_unix) : Bool
      signature = Crypto.unb64(hail.signature, "hail signature")
      @write_mutex.synchronize do
        database.db.transaction do |transaction|
          connection = transaction.connection
          active = connection.query_one?(
            "SELECT 1 FROM ships WHERE name = ? AND state = 'active'",
            hail.recipient_ship, as: Int64
          )
          next false unless active
          ship_a, ship_b = relationship_pair(hail.sender_ship, hail.recipient_ship)
          relationship = connection.query_one?(
            <<-SQL, ship_a, ship_b, hail.sender_ship, hail.recipient_ship, hail.created_at,
              SELECT 1
                FROM relationships
               WHERE ship_a = ? AND ship_b = ? AND state = 'active'
                 AND EXISTS (
                   SELECT 1 FROM hails
                    WHERE sender_ship = ? AND recipient_ship = ?
                      AND allowed_at IS NOT NULL
                      AND expires_at > ?
                 )
            SQL
            as: Int64
          )
          next false if relationship
          pending = connection.scalar(
            "SELECT COUNT(*) FROM hails " +
            "WHERE recipient_ship = ? AND allowed_at IS NULL AND expires_at > ?",
            hail.recipient_ship, now
          ).as(Int64)
          next false if pending >= MAX_UNALLOWED_HAILS_PER_SHIP
          sql = <<-SQL
              INSERT OR IGNORE INTO hails(
                id, sender_ship, sender_signing_generation, recipient_ship,
                created_at, expires_at, signature
              ) VALUES (?, ?, ?, ?, ?, ?, ?)
            SQL
          connection.exec(
            sql, hail.hail_id, hail.sender_ship,
            hail.sender_signing_generation, hail.recipient_ship,
            hail.created_at, hail.expires_at, signature
          ).rows_affected == 1
        end
      end.not_nil!
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

    def acknowledge_hail(request : HailAck,
                         now : Int64 = Time.utc.to_unix) : Nil
      require_uuid!(request.hail_id, "hail id")
      write_transaction do |transaction|
        connection = transaction.connection
        verify_radio_action(connection, request.auth, "hail.ack", request.payload, now)
        connection.exec(
          "UPDATE hails SET collected_at = COALESCE(collected_at, ?) " +
          "WHERE id = ? AND recipient_ship = ?",
          now, request.hail_id, request.auth.ship
        )
      end
    end

    private def ship_card_json(ship : String, now : Int64,
                               include_admin : Bool) : String
      ship_row = database.db.query_one?(
        "SELECT claimed_at, state, admin_generation FROM ships WHERE name = ?",
        ship, as: {Int64, String, Int64}
      ) || raise NotFound.new("ship is not available to this radio")
      JSON.build do |json|
        json.object do
          json.field "ship", ship
          json.field "claimed_at", ship_row[0]
          json.field "state", ship_row[1]
          if include_admin
            json.field "admin_generation", ship_row[2]
          end
          json.field(
            "authority_notice",
            "ship namespace administration only; never human sponsor authority"
          )
          json.field "owner_keys" { write_owner_keys(json, ship) }
          json.field "radio_keys" { write_radio_keys(json, ship) }
        end
      end
    end

    def close_relationship(request : RelationshipClose,
                           now : Int64 = Time.utc.to_unix,
                           exempt_from_rotation_limit : Bool = false) : Nil
      peer = Names.ship!(request.peer_ship)
      retained = request.retained_ships.map { |ship| Names.ship!(ship) }.uniq.sort
      if peer == request.auth.ship || retained.includes?(request.auth.ship)
        raise Invalid.new("a ship cannot retain or close itself")
      end
      raise Invalid.new("closed peer cannot be retained") if retained.includes?(peer)
      certificate = request.certificate
      @write_mutex.synchronize do
        database.db.transaction do |transaction|
          connection = transaction.connection
          verify_owner_action(
            connection, request.auth, "relationship.close", request.payload, now
          )
          unless certificate.ship == request.auth.ship
            raise Invalid.new("radio certificate belongs to another ship")
          end
          prior_generation = connection.scalar(
            "SELECT MAX(generation) FROM ship_radio_keys WHERE ship = ?",
            certificate.ship
          ).as(Int64).to_i
          unless certificate.generation == prior_generation + 1
            raise Invalid.new("radio generation must advance by one")
          end
          verify_radio_certificate(connection, certificate)
          prior_key = radio_key(connection, certificate.ship, prior_generation)
          unless Crypto.verify(
                   certificate.unsigned_bytes,
                   Crypto.unb64(request.prior_radio_signature), prior_key[0]
                 )
            raise Unauthorized.new("radio retune lacks the prior radio signature")
          end
          target_a, target_b = relationship_pair(request.auth.ship, peer)
          unless connection.query_one?(
                   "SELECT 1 FROM relationships " +
                   "WHERE ship_a = ? AND ship_b = ? AND state = 'active'",
                   target_a, target_b, as: Int64
                 )
            raise NotFound.new("active relationship not found")
          end
          unless exempt_from_rotation_limit
            enforce_rotation_budget!(
              connection, certificate.ship, "ship_radio_keys",
              MAX_RADIO_RETUNES_PER_DAY, now
            )
          end
          ensure_permanent_capacity!(connection, 1)
          connection.exec(
            "UPDATE ship_radio_keys SET state = 'rotated', revoked_at = ? " +
            "WHERE ship = ? AND state = 'active'",
            now, certificate.ship
          )
          insert_radio_key(connection, certificate, request.prior_radio_signature)
          deadline = now + MAX_PENDING_SECONDS
          active_peers = [] of String
          connection.query(
            "SELECT ship_a, ship_b FROM relationships " +
            "WHERE state = 'active' AND (ship_a = ? OR ship_b = ?)",
            request.auth.ship, request.auth.ship
          ) do |rows|
            rows.each do
              ship_a, ship_b = rows.read(String, String)
              active_peers << (ship_a == request.auth.ship ? ship_b : ship_a)
            end
          end
          connection.exec(
            "UPDATE relationships SET state = 'transitioning', transition_until = ? " +
            "WHERE state = 'active' AND (ship_a = ? OR ship_b = ?)",
            deadline, request.auth.ship, request.auth.ship
          )
          retained.each do |retained_ship|
            next unless active_peers.includes?(retained_ship)
            connection.exec(
              <<-SQL,
                INSERT INTO relationship_transitions(
                  owner_ship, peer_ship, from_generation, to_generation, expires_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(owner_ship, peer_ship) DO UPDATE SET
                  from_generation = excluded.from_generation,
                  to_generation = excluded.to_generation,
                  expires_at = excluded.expires_at
              SQL
              request.auth.ship,
              retained_ship,
              prior_generation,
              certificate.generation,
              deadline
            )
          end
          advance_admin(connection, request.auth)
        end
      end
    end

    def acknowledge_retune(request : RetuneAck,
                           now : Int64 = Time.utc.to_unix) : Nil
      owner_ship = Names.ship!(request.owner_ship)
      write_transaction do |transaction|
        connection = transaction.connection
        verify_radio_action(
          connection,
          request.auth,
          "relationship.retune.ack",
          request.payload,
          now
        )
        connection.query_one?(
          <<-SQL, owner_ship, request.auth.ship, request.to_generation, now,
              SELECT 1 FROM relationship_transitions
               WHERE owner_ship = ? AND peer_ship = ? AND to_generation = ?
                 AND expires_at > ?
            SQL
          as: Int64
        ) || raise NotFound.new("retune transition is unavailable")
        ship_a, ship_b = relationship_pair(owner_ship, request.auth.ship)
        connection.exec(
          "UPDATE relationships SET state = 'active', transition_until = NULL " +
          "WHERE ship_a = ? AND ship_b = ? AND state = 'transitioning'",
          ship_a, ship_b
        )
        connection.exec(
          "DELETE FROM relationship_transitions WHERE owner_ship = ? AND peer_ship = ?",
          owner_ship, request.auth.ship
        )
      end
    end

    def allow_relationship(request : RelationshipAllow,
                           now : Int64 = Time.utc.to_unix) : Nil
      peer = Names.ship!(request.peer_ship)
      require_uuid!(request.hail_id, "hail id")
      @write_mutex.synchronize do
        database.db.transaction do |transaction|
          connection = transaction.connection
          verify_radio_action(
            connection, request.auth, "relationship.allow", request.payload, now
          )
          connection.query_one?(
            <<-SQL, request.hail_id, peer, request.auth.ship, now,
              SELECT 1 FROM hails
               WHERE id = ? AND sender_ship = ? AND recipient_ship = ?
                 AND collected_at IS NOT NULL AND expires_at > ?
            SQL
            as: Int64
          ) || raise NotFound.new("authenticated hail is unavailable")
          ship_a, ship_b = relationship_pair(request.auth.ship, peer)
          existing = connection.query_one?(
            "SELECT 1 FROM relationships WHERE ship_a = ? AND ship_b = ?",
            ship_a, ship_b, as: Int64
          )
          ensure_permanent_capacity!(connection, 1) unless existing
          connection.exec(
            <<-SQL, ship_a, ship_b
                INSERT INTO relationships(ship_a, ship_b, state)
                VALUES (?, ?, 'active')
              ON CONFLICT(ship_a, ship_b) DO UPDATE SET
                state = 'active', transition_until = NULL
            SQL
          )
          connection.exec(
            "UPDATE hails SET allowed_at = COALESCE(allowed_at, ?) WHERE id = ?",
            now, request.hail_id
          )
        end
      end
    end

    def rotate_owner(rotation : OwnerRotation,
                     now : Int64 = Time.utc.to_unix,
                     exempt_from_rotation_limit : Bool = false) : Nil
      @write_mutex.synchronize do
        database.db.transaction do |transaction|
          connection = transaction.connection
          verify_owner_action(
            connection, rotation.auth, "owner.rotate", rotation.payload, now
          )
          unless rotation.new_generation == rotation.auth.owner_generation + 1
            raise Invalid.new("owner generation must advance by one")
          end
          new_key = decode_owner_public_key(rotation.new_public_key)
          old_key = owner_key(
            connection, rotation.auth.ship, rotation.auth.owner_generation
          )
          bytes = Canonical.fields(
            "tinrelay-owner-rotation-v1",
            rotation.auth.ship,
            rotation.new_generation.to_s,
            rotation.new_public_key
          )
          unless Crypto.verify(bytes, Crypto.unb64(rotation.prior_signature), old_key)
            raise Unauthorized.new("owner rotation lacks the prior owner signature")
          end
          prior_signature = Crypto.unb64(rotation.prior_signature)
          unless exempt_from_rotation_limit
            enforce_rotation_budget!(
              connection, rotation.auth.ship, "ship_owner_keys",
              MAX_OWNER_ROTATIONS_PER_DAY, now
            )
          end
          ensure_permanent_capacity!(connection, 1)
          connection.exec(
            "UPDATE ship_owner_keys SET state = 'rotated', revoked_at = ? " +
            "WHERE ship = ? AND state = 'active'",
            now,
            rotation.auth.ship
          )
          connection.exec(
            <<-SQL, rotation.auth.ship, rotation.new_generation, new_key, now, prior_signature
              INSERT INTO ship_owner_keys(
                ship, generation, public_key, state, valid_from,
                authorization_signature
              ) VALUES (?, ?, ?, 'active', ?, ?)
            SQL
          )
          advance_admin(connection, rotation.auth)
        end
      end
    end

    def ship_change(change : ShipChange,
                    now : Int64 = Time.utc.to_unix) : Nil
      unless change.operation.in?({"freeze", "activate", "revoke"})
        raise Invalid.new("ship operation must be freeze, activate, or revoke")
      end
      write_transaction do |transaction|
        connection = transaction.connection
        verify_owner_action(connection, change.auth, "ship.change", change.payload, now)
        current = connection.scalar(
          "SELECT state FROM ships WHERE name = ?",
          change.auth.ship
        ).as(String)
        raise Conflict.new("revoked ships cannot be reactivated") if current == "revoked"
        state = case change.operation
                when "activate" then "active"
                when "revoke"   then "revoked"
                else                 "frozen"
                end
        connection.exec(
          "UPDATE ships SET state = ? WHERE name = ?",
          state, change.auth.ship
        )
        if state == "revoked"
          connection.exec(
            "UPDATE ship_owner_keys SET state = 'revoked', revoked_at = ? " +
            "WHERE ship = ? AND state = 'active'",
            now,
            change.auth.ship
          )
          connection.exec(
            "UPDATE ship_radio_keys SET state = 'revoked', revoked_at = ? " +
            "WHERE ship = ? AND state = 'active'",
            now,
            change.auth.ship
          )
        end
        advance_admin(connection, change.auth)
      end
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
        %w[pending collected expired].each do |state|
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

    private def pending_hail(connection : DB::Connection, ship : String,
                             known : Hash(String, Int32),
                             now : Int64) : HailDelivery?
      row = connection.query_one?(
        <<-SQL, ship, now,
          SELECT h.id, h.sender_ship, h.sender_signing_generation,
                 h.created_at, h.expires_at, h.signature,
                 r.signing_public_key, r.encryption_public_key, r.issued_at,
                 r.owner_generation, r.owner_signature, o.public_key
            FROM hails h
            JOIN ship_radio_keys r
              ON r.ship = h.sender_ship
             AND r.generation = h.sender_signing_generation
            JOIN ship_owner_keys o
              ON o.ship = r.ship AND o.generation = r.owner_generation
           WHERE h.recipient_ship = ? AND h.expires_at > ?
             AND h.collected_at IS NULL AND h.allowed_at IS NULL
           ORDER BY h.created_at, h.rowid LIMIT 1
        SQL
        as: {String, String, Int64, Int64, Int64, Bytes,
             Bytes, Bytes, Int64, Int64, Bytes, Bytes}
      )
      return nil unless row
      hail = Hail.new(
        row[0], row[1], row[2].to_i, ship, row[3], row[4], Crypto.b64(row[5])
      )
      certificate = ShipRadioCertificate.new(
        row[1], row[2].to_i, Crypto.b64(row[6]), Crypto.b64(row[7]),
        row[8], row[9].to_i, Crypto.b64(row[10])
      )
      chain = known[row[1]]?.try do |generation|
        radio_chain(connection, row[1], generation, row[2].to_i)
      end || [] of RadioCertificateLink
      owner_chain = known[row[1]]?.try do |generation|
        from_owner = owner_generation_for_radio(connection, row[1], generation)
        owner_chain(connection, row[1], from_owner, certificate.owner_generation)
      end || [] of OwnerKeyLink
      HailDelivery.new(
        hail, Crypto.b64(row[11]), certificate, owner_chain, chain
      )
    end

    private def contact_updates(connection : DB::Connection, ship : String,
                                known : Hash(String, Int32),
                                now : Int64) : Array(ContactUpdate)
      updates = [] of ContactUpdate
      connection.query(
        <<-SQL, ship, now
          SELECT owner_ship, from_generation, to_generation
            FROM relationship_transitions
           WHERE peer_ship = ? AND expires_at > ?
           ORDER BY owner_ship
        SQL
      ) do |rows|
        rows.each do
          owner_ship, from_generation, to_generation = rows.read(
            String, Int64, Int64
          )
          next unless known[owner_ship]? == from_generation.to_i
          chain = radio_chain(
            connection, owner_ship, from_generation.to_i, to_generation.to_i
          )
          from_owner = owner_generation_for_radio(
            connection, owner_ship, from_generation.to_i
          )
          to_owner = chain.last.certificate.owner_generation
          updates << ContactUpdate.new(
            owner_ship, to_generation.to_i,
            owner_chain(connection, owner_ship, from_owner, to_owner), chain
          )
        end
      end
      updates
    end

    private def radio_chain(connection : DB::Connection, ship : String,
                            from_generation : Int32,
                            to_generation : Int32) : Array(RadioCertificateLink)
      links = [] of RadioCertificateLink
      connection.query(
        <<-SQL, ship, from_generation, to_generation
          SELECT generation, signing_public_key, encryption_public_key,
                 issued_at, owner_generation, owner_signature,
                 prior_radio_signature
            FROM ship_radio_keys
           WHERE ship = ? AND generation > ? AND generation <= ?
           ORDER BY generation
        SQL
      ) do |rows|
        rows.each do
          values = rows.read(
            Int64, Bytes, Bytes, Int64, Int64, Bytes, Bytes?
          )
          generation = values[0]
          signing = values[1]
          encryption = values[2]
          issued_at = values[3]
          owner_generation = values[4]
          owner_signature = values[5]
          prior_signature = values[6]
          certificate = ShipRadioCertificate.new(
            ship, generation.to_i, Crypto.b64(signing), Crypto.b64(encryption),
            issued_at, owner_generation.to_i, Crypto.b64(owner_signature)
          )
          links << RadioCertificateLink.new(
            certificate,
            prior_signature.try { |signature| Crypto.b64(signature) }
          )
        end
      end
      expected = to_generation - from_generation
      raise Error.new("radio continuity chain is incomplete") unless links.size == expected
      links
    end

    private def owner_generation_for_radio(connection : DB::Connection,
                                           ship : String,
                                           generation : Int32) : Int32
      connection.query_one(
        "SELECT owner_generation FROM ship_radio_keys WHERE ship = ? AND generation = ?",
        ship, generation, as: Int64
      ).to_i
    end

    private def owner_chain(connection : DB::Connection, ship : String,
                            from_generation : Int32,
                            to_generation : Int32) : Array(OwnerKeyLink)
      links = [] of OwnerKeyLink
      connection.query(
        <<-SQL, ship, from_generation, to_generation
          SELECT generation, public_key, authorization_signature
            FROM ship_owner_keys
           WHERE ship = ? AND generation > ? AND generation <= ?
           ORDER BY generation
        SQL
      ) do |rows|
        rows.each do
          generation, public_key, signature = rows.read(Int64, Bytes, Bytes?)
          links << OwnerKeyLink.new(
            generation.to_i, Crypto.b64(public_key),
            signature.try { |value| Crypto.b64(value) }
          )
        end
      end
      unless links.size == to_generation - from_generation
        raise Error.new("owner continuity chain is incomplete")
      end
      links
    end

    private def radio_key(connection : DB::Connection, ship : String,
                          generation : Int32) : Tuple(Bytes, Bytes, String)
      connection.query_one?(
        "SELECT signing_public_key, encryption_public_key, state " +
        "FROM ship_radio_keys WHERE ship = ? AND generation = ?",
        ship, generation, as: {Bytes, Bytes, String}
      ) || raise Unauthorized.new("ship radio key is not registered")
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
      key = connection.query_one?(
        "SELECT signing_public_key, encryption_public_key, state " +
        "FROM ship_radio_keys WHERE ship = ? AND generation = ?",
        ship, generation, as: {Bytes, Bytes, String}
      )
      verification_key = key.try(&.[0]) || dummy_signing_public_key
      unauthenticated! unless Crypto.verify(
                                signed_bytes, signature, verification_key
                              ) && key
      key.not_nil!
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

    private def advance_admin(connection : DB::Connection, auth : OwnerAuth) : Nil
      connection.exec(
        "UPDATE ships SET admin_generation = ? WHERE name = ?",
        auth.admin_generation,
        auth.ship
      )
    end

    private def verify_radio_certificate(connection : DB::Connection,
                                         certificate : ShipRadioCertificate) : Nil
      owner = owner_key(connection, certificate.ship, certificate.owner_generation)
      unless Crypto.verify(
               certificate.unsigned_bytes,
               Crypto.unb64(certificate.owner_signature),
               owner
             )
        raise Unauthorized.new("radio certificate is not owner-authorized")
      end
    end

    private def decode_owner_public_key(encoded : String) : Bytes
      key = Crypto.unb64(encoded, "owner public key")
      unless key.size == Crypto::SIGN_PUBLIC_BYTES
        raise Invalid.new("invalid owner public key length")
      end
      key
    end

    private def decode_radio_public_keys(
      certificate : ShipRadioCertificate,
    ) : Tuple(Bytes, Bytes)
      signing = Crypto.unb64(certificate.signing_public_key, "radio signing public key")
      encryption = Crypto.unb64(
        certificate.encryption_public_key, "radio encryption public key"
      )
      unless signing.size == Crypto::SIGN_PUBLIC_BYTES
        raise Invalid.new("invalid radio signing public key length")
      end
      unless encryption.size == Crypto::BOX_PUBLIC_BYTES
        raise Invalid.new("invalid radio encryption public key length")
      end
      {signing, encryption}
    end

    private def insert_radio_key(connection : DB::Connection,
                                 certificate : ShipRadioCertificate,
                                 prior_radio_signature : String? = nil) : Nil
      signing, encryption = decode_radio_public_keys(certificate)
      owner_signature = Crypto.unb64(certificate.owner_signature)
      prior_signature = prior_radio_signature.try { |value| Crypto.unb64(value) }
      connection.exec(
        <<-SQL,
          INSERT INTO ship_radio_keys(
            ship, generation, signing_public_key, encryption_public_key,
            state, issued_at, owner_generation, owner_signature,
            prior_radio_signature
          ) VALUES (?, ?, ?, ?, 'active', ?, ?, ?, ?)
        SQL
        certificate.ship,
        certificate.generation,
        signing,
        encryption,
        certificate.issued_at,
        certificate.owner_generation,
        owner_signature,
        prior_signature
      )
    end

    private def permanent_metadata_usage(connection) : Int64
      connection.scalar(
        <<-SQL
          SELECT (SELECT COUNT(*) FROM ships) +
                 (SELECT COUNT(*) FROM ship_owner_keys) +
                 (SELECT COUNT(*) FROM ship_radio_keys) +
                 (SELECT COUNT(*) FROM relationships)
        SQL
      ).as(Int64)
    end

    private def ensure_permanent_capacity!(connection : DB::Connection,
                                           growth : Int32) : Nil
      used = permanent_metadata_usage(connection)
      if used > permanent_metadata_limit - growth
        raise Unavailable.new("permanent metadata capacity is exhausted")
      end
    end

    private def registration_retry_after(
      connection : DB::Connection,
      source_bucket : String,
      allowances : RegistrationAllowances,
      now : Int64,
    ) : Int64?
      retries = [] of Int64
      registration_window_retry_at(
        connection, nil, now - REGISTRATION_HOUR_SECONDS,
        allowances.global_hour, REGISTRATION_HOUR_SECONDS
      ).try { |retry_at| retries << retry_at }
      registration_window_retry_at(
        connection, nil, now - REGISTRATION_DAY_SECONDS,
        allowances.global_day, REGISTRATION_DAY_SECONDS
      ).try { |retry_at| retries << retry_at }
      registration_window_retry_at(
        connection, source_bucket, now - REGISTRATION_HOUR_SECONDS,
        allowances.per_source_hour, REGISTRATION_HOUR_SECONDS
      ).try { |retry_at| retries << retry_at }
      registration_window_retry_at(
        connection, source_bucket, now - REGISTRATION_DAY_SECONDS,
        allowances.per_source_day, REGISTRATION_DAY_SECONDS
      ).try { |retry_at| retries << retry_at }
      return nil if retries.empty?
      retry_after = retries.max - now
      raise Error.new("registration limit produced a non-positive retry time") if retry_after <= 0
      retry_after
    end

    private def registration_window_retry_at(
      connection : DB::Connection,
      source_bucket : String?,
      cutoff : Int64,
      allowance : Int32,
      window_seconds : Int64,
    ) : Int64?
      count = if source_bucket
                connection.scalar(
                  "SELECT COUNT(*) FROM registration_events " +
                  "WHERE source_bucket = ? AND accepted_at > ?",
                  source_bucket, cutoff
                ).as(Int64)
              else
                connection.scalar(
                  "SELECT COUNT(*) FROM registration_events WHERE accepted_at > ?",
                  cutoff
                ).as(Int64)
              end
      return nil if count < allowance
      offset = count - allowance
      accepted_at = if source_bucket
                      connection.query_one(
                        "SELECT accepted_at FROM registration_events " +
                        "WHERE source_bucket = ? AND accepted_at > ? " +
                        "ORDER BY accepted_at ASC LIMIT 1 OFFSET ?",
                        source_bucket, cutoff, offset, as: Int64
                      )
                    else
                      connection.query_one(
                        "SELECT accepted_at FROM registration_events " +
                        "WHERE accepted_at > ? " +
                        "ORDER BY accepted_at ASC LIMIT 1 OFFSET ?",
                        cutoff, offset, as: Int64
                      )
                    end
      accepted_at + window_seconds
    end

    private def enforce_rotation_budget!(connection : DB::Connection,
                                         ship : String, table : String,
                                         allowance : Int32, now : Int64) : Nil
      missing_time = connection.query_one?(
        "SELECT 1 FROM #{table} " +
        "WHERE ship = ? AND state = 'rotated' AND revoked_at IS NULL LIMIT 1",
        ship, as: Int64
      )
      if missing_time
        raise Error.new("rotated key history lacks a revocation time")
      end

      cutoff = now - ROTATION_WINDOW_SECONDS
      recent = connection.scalar(
        "SELECT COUNT(*) FROM #{table} " +
        "WHERE ship = ? AND state = 'rotated' AND revoked_at > ?",
        ship, cutoff
      ).as(Int64)
      return if recent < allowance

      # With M recent rows and allowance L, the (M-L+1)th expiry is the first
      # instant that puts the ship below its limit. revoked_at is server-written;
      # generation order is not time order when the wall clock moves backward.
      reopening_time = connection.query_one(
        "SELECT revoked_at FROM #{table} " +
        "WHERE ship = ? AND state = 'rotated' AND revoked_at > ? " +
        "ORDER BY revoked_at ASC LIMIT 1 OFFSET ?",
        ship, cutoff, recent - allowance, as: Int64
      )
      retry_after = reopening_time + ROTATION_WINDOW_SECONDS - now
      if retry_after <= 0
        raise Error.new("rotation limit produced a non-positive retry time")
      end
      raise RotationLimited.new(retry_after)
    end

    private def write_owner_keys(json : JSON::Builder, ship : String) : Nil
      json.array do
        database.db.query(
          "SELECT generation, public_key, state, valid_from, revoked_at, " +
          "authorization_signature FROM ship_owner_keys " +
          "WHERE ship = ? ORDER BY generation",
          ship
        ) do |rows|
          rows.each do
            generation, key, state, valid_from, revoked_at, authorization_signature = rows.read(
              Int64, Bytes, String, Int64, Int64?, Bytes?
            )
            json.object do
              json.field "generation", generation
              json.field "public_key", Crypto.b64(key)
              json.field "fingerprint", Crypto.fingerprint(key)
              json.field "state", state
              json.field "valid_from", valid_from
              json.field "revoked_at", revoked_at
              json.field(
                "authorization_signature",
                authorization_signature.try { |signature| Crypto.b64(signature) }
              )
            end
          end
        end
      end
    end

    private def write_radio_keys(json : JSON::Builder, ship : String) : Nil
      json.array do
        database.db.query(
          <<-SQL, ship
            SELECT generation, signing_public_key, encryption_public_key,
                   state, issued_at, owner_generation, owner_signature,
                   prior_radio_signature, revoked_at
              FROM ship_radio_keys WHERE ship = ? ORDER BY generation
          SQL
        ) do |rows|
          rows.each do
            values = rows.read(
              Int64, Bytes, Bytes, String, Int64, Int64, Bytes, Bytes?, Int64?
            )
            generation = values[0]
            signing = values[1]
            encryption = values[2]
            state = values[3]
            issued_at = values[4]
            owner_generation = values[5]
            owner_signature = values[6]
            prior_signature = values[7]
            revoked_at = values[8]
            json.object do
              json.field "generation", generation
              json.field "signing_public_key", Crypto.b64(signing)
              json.field "encryption_public_key", Crypto.b64(encryption)
              json.field "signing_fingerprint", Crypto.fingerprint(signing)
              json.field "encryption_fingerprint", Crypto.fingerprint(encryption)
              json.field "state", state
              json.field "issued_at", issued_at
              json.field "owner_generation", owner_generation
              json.field "owner_signature", Crypto.b64(owner_signature)
              json.field(
                "prior_radio_signature",
                prior_signature.try { |signature| Crypto.b64(signature) }
              )
              json.field "revoked_at", revoked_at
            end
          end
        end
      end
    end

    private def require_uuid!(value : String, label : String) : Nil
      raise Invalid.new("invalid #{label}") unless UUID.matches?(value)
    end

    private def relationship_pair(first : String,
                                  second : String) : Tuple(String, String)
      first < second ? {first, second} : {second, first}
    end
  end
end
