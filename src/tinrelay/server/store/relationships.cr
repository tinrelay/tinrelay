module Tinrelay
  class Store
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
      ship_card_json(target, include_admin: requester == target)
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
      write_transaction do |transaction|
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
        publish_retune_transition(connection, request, retained, prior_generation, now)
        advance_admin(connection, request.auth)
      end
    end

    private def publish_retune_transition(connection : DB::Connection,
                                          request : RelationshipClose,
                                          retained : Array(String),
                                          prior_generation : Int32, now : Int64) : Nil
      ship = request.auth.ship
      deadline = now + MAX_PENDING_SECONDS
      active_peers = [] of String
      connection.query(
        "SELECT ship_a, ship_b FROM relationships " +
        "WHERE state = 'active' AND (ship_a = ? OR ship_b = ?)",
        ship, ship
      ) do |rows|
        rows.each do
          ship_a, ship_b = rows.read(String, String)
          active_peers << (ship_a == ship ? ship_b : ship_a)
        end
      end
      connection.exec(
        "UPDATE relationships SET state = 'transitioning', transition_until = ? " +
        "WHERE state = 'active' AND (ship_a = ? OR ship_b = ?)",
        deadline, ship, ship
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
          ship,
          retained_ship,
          prior_generation,
          request.certificate.generation,
          deadline
        )
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
      write_transaction do |transaction|
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

    private def ship_card_json(ship : String, include_admin : Bool) : String
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

    private def relationship_pair(first : String,
                                  second : String) : Tuple(String, String)
      first < second ? {first, second} : {second, first}
    end
  end
end
