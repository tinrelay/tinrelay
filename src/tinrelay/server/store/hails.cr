module Tinrelay
  class Store
    MAX_HAILS_PER_DAY            = 12
    MAX_UNALLOWED_HAILS_PER_SHIP = 12

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
  end
end
