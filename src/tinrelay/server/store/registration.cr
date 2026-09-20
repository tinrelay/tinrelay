module Tinrelay
  class PreparedShipClaim
    getter ship : String
    getter owner_key : Bytes
    getter certificate : ShipRadioCertificate

    def initialize(@ship, @owner_key, @certificate)
    end
  end

  class Store
    REGISTRATION_HOUR_SECONDS = 60_i64 * 60
    REGISTRATION_DAY_SECONDS  = 24_i64 * REGISTRATION_HOUR_SECONDS

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

    def permanent_metadata_usage : Int64
      permanent_metadata_usage(database.db)
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
  end
end
