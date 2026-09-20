module Tinrelay
  class Store
    MAX_OWNER_ROTATIONS_PER_DAY =  4
    MAX_RADIO_RETUNES_PER_DAY   = 16
    ROTATION_WINDOW_SECONDS     = 24 * 60 * 60

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
  end
end
