require "./spec_helper"

module TinrelayPermanentMetadataSpec
  def self.seed_owner_history(api : Tinrelay::API, client : Tinrelay::Client,
                              revoked_at : Array(Int64?)) : Int32
    return 1 if revoked_at.empty?
    ship = client.keyring.data.ship
    public_key = Tinrelay::Crypto.unb64(client.keyring.owner.key.public_key)
    api.database.db.transaction do |transaction|
      connection = transaction.connection
      connection.exec(
        "UPDATE ship_owner_keys SET state = 'rotated', revoked_at = ? " +
        "WHERE ship = ? AND generation = 1",
        revoked_at.first, ship
      )
      revoked_at.each_with_index do |timestamp, index|
        generation = index + 1
        next if generation == 1
        connection.exec(
          "INSERT INTO ship_owner_keys(" +
          "ship, generation, public_key, state, valid_from, revoked_at" +
          ") VALUES (?, ?, ?, 'rotated', 0, ?)",
          ship, generation, Tinrelay::Crypto.signing_keypair.public_key, timestamp
        )
      end
      active_generation = revoked_at.size + 1
      connection.exec(
        "INSERT INTO ship_owner_keys(" +
        "ship, generation, public_key, state, valid_from" +
        ") VALUES (?, ?, ?, 'active', 0)",
        ship, active_generation, public_key
      )
      active_generation
    end.not_nil!.to_i
  end

  def self.owner_rotation(client : Tinrelay::Client,
                          current_generation : Int32, admin_generation : Int64,
                          now : Int64) : Tinrelay::OwnerRotation
    keys = Tinrelay::Crypto.signing_keypair
    public_key = Tinrelay::Crypto.b64(keys.public_key)
    owner = client.keyring.owner.key
    bytes = Tinrelay::Canonical.fields(
      "tinrelay-owner-rotation-v1", client.keyring.data.ship,
      (current_generation + 1).to_s, public_key
    )
    prior_signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(bytes, Tinrelay::Crypto.unb64(owner.secret_key))
    )
    auth = Tinrelay::OwnerAuth.new(
      client.keyring.data.ship, current_generation, admin_generation, now
    )
    rotation = Tinrelay::OwnerRotation.new(
      current_generation + 1, public_key, prior_signature, auth
    )
    auth.signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        auth.signing_bytes("owner.rotate", rotation.payload),
        Tinrelay::Crypto.unb64(owner.secret_key)
      )
    )
    rotation
  end

  def self.seed_radio_history(api : Tinrelay::API, client : Tinrelay::Client,
                              owner_generation : Int32,
                              revoked_at : Array(Int64?)) : Int32
    return 1 if revoked_at.empty?
    ship = client.keyring.data.ship
    radio = client.keyring.data.radio!
    owner = client.keyring.owner.key
    api.database.db.transaction do |transaction|
      connection = transaction.connection
      connection.exec(
        "UPDATE ship_radio_keys SET state = 'rotated', revoked_at = ? " +
        "WHERE ship = ? AND generation = 1",
        revoked_at.first, ship
      )
      revoked_at.each_with_index do |timestamp, index|
        generation = index + 1
        next if generation == 1
        connection.exec(
          "INSERT INTO ship_radio_keys(" +
          "ship, generation, signing_public_key, encryption_public_key, " +
          "state, issued_at, owner_generation, owner_signature, revoked_at" +
          ") VALUES (?, ?, ?, ?, 'rotated', 0, ?, ?, ?)",
          ship, generation, Tinrelay::Crypto.signing_keypair.public_key,
          Tinrelay::Crypto.box_keypair.public_key, owner_generation,
          Bytes.new(Tinrelay::Crypto::SIGNATURE_BYTES), timestamp
        )
      end
      active_generation = revoked_at.size + 1
      certificate = Tinrelay::ShipRadioCertificate.new(
        ship, active_generation, radio.signing.public_key,
        radio.encryption.public_key, 0_i64, owner_generation
      )
      certificate.owner_signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.sign(
          certificate.unsigned_bytes, Tinrelay::Crypto.unb64(owner.secret_key)
        )
      )
      connection.exec(
        "INSERT INTO ship_radio_keys(" +
        "ship, generation, signing_public_key, encryption_public_key, " +
        "state, issued_at, owner_generation, owner_signature" +
        ") VALUES (?, ?, ?, ?, 'active', 0, ?, ?)",
        ship, active_generation, Tinrelay::Crypto.unb64(radio.signing.public_key),
        Tinrelay::Crypto.unb64(radio.encryption.public_key), owner_generation,
        Tinrelay::Crypto.unb64(certificate.owner_signature)
      )
      active_generation
    end.not_nil!.to_i
  end

  def self.relationship_close(client : Tinrelay::Client,
                              peer : String, radio_generation : Int32,
                              owner_generation : Int32, admin_generation : Int64,
                              now : Int64) : Tinrelay::RelationshipClose
    prior = client.keyring.data.radio!
    owner = client.keyring.owner.key
    signing = Tinrelay::Crypto.signing_keypair
    encryption = Tinrelay::Crypto.box_keypair
    certificate = Tinrelay::ShipRadioCertificate.new(
      client.keyring.data.ship, radio_generation + 1,
      Tinrelay::Crypto.b64(signing.public_key),
      Tinrelay::Crypto.b64(encryption.public_key), now, owner_generation
    )
    certificate.owner_signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        certificate.unsigned_bytes, Tinrelay::Crypto.unb64(owner.secret_key)
      )
    )
    prior_signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        certificate.unsigned_bytes,
        Tinrelay::Crypto.unb64(prior.signing.secret_key)
      )
    )
    auth = Tinrelay::OwnerAuth.new(
      client.keyring.data.ship, owner_generation, admin_generation, now
    )
    closure = Tinrelay::RelationshipClose.new(
      peer, [] of String, certificate, prior_signature, auth
    )
    auth.signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        auth.signing_bytes("relationship.close", closure.payload),
        Tinrelay::Crypto.unb64(owner.secret_key)
      )
    )
    closure
  end

  def self.post(origin : String, path : String, body : String) : HTTP::Client::Response
    HTTP::Client.post(
      "#{origin}#{path}",
      HTTP::Headers{
        "Content-Type"        => "application/json",
        "X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s,
      },
      body
    )
  end
end

describe "permanent relay metadata capacity" do
  it "bounds one ship before it exhausts shared permanent capacity" do
    TinrelaySpec.with_server(permanent_metadata_limit: 14_i64) do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit(root, origin, "beta")

      Tinrelay::Store::MAX_OWNER_ROTATIONS_PER_DAY.times do |index|
        alpha.rotate_owner.should eq(index + 2)
      end
      expect_raises(Tinrelay::RotationLimited) { alpha.rotate_owner }

      beta.rotate_owner.should eq(2)
      TinrelaySpec.admit(root, origin, "gamma")
      api.store.permanent_metadata_usage.should eq(14)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM ship_owner_keys WHERE ship = 'alpha'"
      ).as(Int64).should eq(5)
    end
  end

  it "limits recent owner rotations by timestamp rank without a lifetime ceiling" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      now = 100_000_i64
      cutoff = now - Tinrelay::Store::ROTATION_WINDOW_SECONDS
      old_history = Array(Int64?).new(300, cutoff)
      generation = TinrelayPermanentMetadataSpec.seed_owner_history(
        api, alpha, old_history
      )
      api.store.rotate_owner(
        TinrelayPermanentMetadataSpec.owner_rotation(
          alpha, generation, 1_i64, now
        ),
        now
      )

      beta = TinrelaySpec.admit(root, origin, "beta")
      recent = [cutoff + 40, cutoff + 10, cutoff + 10, cutoff + 30, cutoff + 20]
        .map(&.as(Int64?))
      beta_generation = TinrelayPermanentMetadataSpec.seed_owner_history(
        api, beta, recent
      )
      request = TinrelayPermanentMetadataSpec.owner_rotation(
        beta, beta_generation, 1_i64, now
      )
      limited = expect_raises(Tinrelay::RotationLimited) do
        api.store.rotate_owner(request, now)
      end
      limited.retry_after_seconds.should eq(10)
      api.database.db.scalar(
        "SELECT admin_generation FROM ships WHERE name = 'beta'"
      ).should eq(0_i64)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM ship_owner_keys WHERE ship = 'beta'"
      ).should eq(6_i64)

      api.store.rotate_owner(request, now + limited.retry_after_seconds)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM ship_owner_keys WHERE ship = 'beta'"
      ).should eq(7_i64)
    end
  end

  it "orders a backward-clock rotation window by server time and rejects NULL history" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      timestamps = [100_i64, 90_i64, 80_i64, 70_i64, 60_i64].map(&.as(Int64?))
      generation = TinrelayPermanentMetadataSpec.seed_owner_history(
        api, alpha, timestamps
      )
      request = TinrelayPermanentMetadataSpec.owner_rotation(
        alpha, generation, 1_i64, 50_i64
      )
      limited = expect_raises(Tinrelay::RotationLimited) do
        api.store.rotate_owner(request, 50_i64)
      end
      limited.retry_after_seconds.should eq(
        Tinrelay::Store::ROTATION_WINDOW_SECONDS + 20
      )

      beta = TinrelaySpec.admit(root, origin, "beta")
      beta_generation = TinrelayPermanentMetadataSpec.seed_owner_history(
        api, beta, [nil]
      )
      beta_request = TinrelayPermanentMetadataSpec.owner_rotation(
        beta, beta_generation, 1_i64, 50_i64
      )
      expect_raises(Tinrelay::Error, /revocation time/) do
        api.store.rotate_owner(beta_request, 50_i64)
      end
    end
  end

  it "returns exact timed evidence and no retry time for corrupt rotation history" do
    TinrelaySpec.with_server do |root, origin, api|
      now = Time.utc.to_unix
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      generation = TinrelayPermanentMetadataSpec.seed_owner_history(
        api, alpha, Array(Int64?).new(4, now - 10)
      )
      request = TinrelayPermanentMetadataSpec.owner_rotation(
        alpha, generation, 1_i64, now
      )
      response = TinrelayPermanentMetadataSpec.post(
        origin, "/v1/owners/rotate", request.to_json
      )
      response.status_code.should eq(429)
      retry_after = response.headers["Retry-After"].to_i64
      retry_after.should be > 0
      evidence = JSON.parse(response.body).as_h
      evidence.keys.sort.should eq(%w(error retry_after_seconds))
      evidence["error"].as_s.should eq("rotation_limited")
      evidence["retry_after_seconds"].as_i64.should eq(retry_after)

      beta = TinrelaySpec.admit(root, origin, "beta")
      beta_generation = TinrelayPermanentMetadataSpec.seed_owner_history(
        api, beta, [nil]
      )
      invalid = TinrelayPermanentMetadataSpec.owner_rotation(
        beta, beta_generation, 1_i64, Time.utc.to_unix
      )
      corrupt = TinrelayPermanentMetadataSpec.post(
        origin, "/v1/owners/rotate", invalid.to_json
      )
      corrupt.status_code.should eq(500)
      corrupt.headers["Retry-After"]?.should be_nil
    end
  end

  it "keeps owner and radio rotation budgets independent and mutation-free" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit(root, origin, "beta")
      TinrelaySpec.connect(root, alpha, beta)
      now = 200_000_i64
      radio_generation = TinrelayPermanentMetadataSpec.seed_radio_history(
        api, alpha, 1,
        Array(Int64?).new(Tinrelay::Store::MAX_RADIO_RETUNES_PER_DAY, now - 1)
      )
      closure = TinrelayPermanentMetadataSpec.relationship_close(
        alpha, "beta", radio_generation, 1, 1_i64, now
      )
      limited = expect_raises(Tinrelay::RotationLimited) do
        api.store.close_relationship(closure, now)
      end
      limited.retry_after_seconds.should eq(
        Tinrelay::Store::ROTATION_WINDOW_SECONDS - 1
      )
      api.database.db.scalar(
        "SELECT admin_generation FROM ships WHERE name = 'alpha'"
      ).should eq(0_i64)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM ship_radio_keys WHERE ship = 'alpha'"
      ).should eq((Tinrelay::Store::MAX_RADIO_RETUNES_PER_DAY + 1).to_i64)
      api.database.db.query_one(
        "SELECT state FROM relationships WHERE ship_a = 'alpha' AND ship_b = 'beta'",
        as: String
      ).should eq("active")

      owner_request = TinrelayPermanentMetadataSpec.owner_rotation(
        alpha, 1, 1_i64, now
      )
      api.store.rotate_owner(owner_request, now)
    end

    TinrelaySpec.with_server do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit(root, origin, "beta")
      TinrelaySpec.connect(root, alpha, beta)
      now = 300_000_i64
      cutoff = now - Tinrelay::Store::ROTATION_WINDOW_SECONDS
      owner_generation = TinrelayPermanentMetadataSpec.seed_owner_history(
        api, alpha,
        Array(Int64?).new(Tinrelay::Store::MAX_OWNER_ROTATIONS_PER_DAY, cutoff + 1)
      )
      radio_generation = TinrelayPermanentMetadataSpec.seed_radio_history(
        api, alpha, owner_generation,
        Array(Int64?).new(Tinrelay::Store::MAX_RADIO_RETUNES_PER_DAY - 1, now - 1)
      )
      closure = TinrelayPermanentMetadataSpec.relationship_close(
        alpha, "beta", radio_generation,
        owner_generation, 1_i64, now
      )
      api.store.close_relationship(closure, now)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM ship_radio_keys WHERE ship = 'alpha'"
      ).should eq((Tinrelay::Store::MAX_RADIO_RETUNES_PER_DAY + 1).to_i64)
    end
  end

  it "serializes concurrent permanent growth at the configured boundary" do
    root = TinrelaySpec.temporary_root
    database = Tinrelay::Database.new(File.join(root, "capacity.db"), 2)
    store = Tinrelay::Store.new(database, 3_i64)
    prepared = %w(alpha beta).map do |ship|
      owner = Tinrelay::Crypto.signing_keypair
      signing = Tinrelay::Crypto.signing_keypair
      encryption = Tinrelay::Crypto.box_keypair
      certificate = Tinrelay::ShipRadioCertificate.new(
        ship, 1, Tinrelay::Crypto.b64(signing.public_key),
        Tinrelay::Crypto.b64(encryption.public_key), Time.utc.to_unix, 1
      )
      certificate.owner_signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.sign(certificate.unsigned_bytes, owner.secret_key)
      )
      store.prepare_claim(Tinrelay::ShipClaim.new(
        ship, Tinrelay::Crypto.b64(owner.public_key), certificate
      ))
    end
    results = Channel(Exception?).new(2)

    prepared.each do |claim|
      spawn do
        begin
          TinrelaySpec.claim_directly(store, claim)
          results.send(nil)
        rescue ex
          results.send(ex)
        end
      end
    end

    outcomes = 2.times.map { TinrelaySpec.receive(results) }.to_a
    outcomes.count(&.nil?).should eq(1)
    outcomes.compact.first.should be_a(Tinrelay::Unavailable)
    store.permanent_metadata_usage.should eq(3)
  ensure
    database.try(&.close)
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "rejects growing claims while established correspondence remains writable" do
    TinrelaySpec.with_server(permanent_metadata_limit: 3_i64) do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")

      expect_raises(Tinrelay::Unavailable) do
        TinrelaySpec.admit(root, origin, "beta")
      end
      api.database.db.scalar("SELECT COUNT(*) FROM registration_events").should eq(1_i64)
      api.store.permanent_metadata_usage.should eq(3)
      below_limit = Tinrelay::Store.new(api.database, 2_i64)
      below_limit.permanent_metadata_usage.should eq(3)
      below_limit.wait_once(TinrelaySpec.radio_wait_request(alpha, 0)).empty?.should be_true

      sent = alpha.send("steward@alpha", "capacity leaves correspondence working")
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", sent.transmission_id
      ).as(Int64).should eq(1)
    end
  end

  it "charges owner and radio generations but not an existing relationship update" do
    TinrelaySpec.with_server(permanent_metadata_limit: 7_i64) do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit(root, origin, "beta")
      TinrelaySpec.connect(root, alpha, beta)

      api.store.permanent_metadata_usage.should eq(7)
      hail_id = api.database.db.query_one(
        "SELECT id FROM hails WHERE sender_ship = 'beta' AND recipient_ship = 'alpha'",
        as: String
      )
      repeated = Tinrelay::RelationshipAllow.new(
        "beta", hail_id, Tinrelay::RadioAuth.new("alpha", 1, 0_i64)
      )
      repeated.auth = TinrelaySpec.radio_auth(
        alpha, "relationship.allow", repeated.payload
      )
      api.store.allow_relationship(repeated)
      api.store.permanent_metadata_usage.should eq(7)

      expect_raises(Tinrelay::Unavailable) { alpha.rotate_owner }
      expect_raises(Tinrelay::Unavailable) { alpha.close_contact("beta") }

      api.database.db.scalar(
        "SELECT COUNT(*) FROM ship_owner_keys WHERE ship = 'alpha'"
      ).as(Int64).should eq(1)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM ship_radio_keys WHERE ship = 'alpha'"
      ).as(Int64).should eq(1)
      api.database.db.query_one(
        "SELECT state FROM relationships WHERE ship_a = 'alpha' AND ship_b = 'beta'",
        as: String
      ).should eq("active")
    end
  end

  it "leaves a hail unallowed when a new relationship would exceed capacity" do
    TinrelaySpec.with_server(permanent_metadata_limit: 6_i64) do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit(root, origin, "beta")
      spool = Tinrelay::Spool.new(File.join(root, "beta-inbox"))

      alpha.hail("beta")
      event = beta.radio_wait(spool, hold_seconds: 0)
      hail_id = spool.get(event.local_id).as(Tinrelay::HailSpoolRecord).hail_id
      request = Tinrelay::RelationshipAllow.new(
        "alpha", hail_id, Tinrelay::RadioAuth.new("beta", 1, 0_i64)
      )
      request.auth = TinrelaySpec.radio_auth(
        beta, "relationship.allow", request.payload
      )

      expect_raises(Tinrelay::Unavailable) do
        api.store.allow_relationship(request)
      end
      api.database.db.scalar("SELECT COUNT(*) FROM relationships").should eq(0)
      api.database.db.query_one(
        "SELECT allowed_at IS NULL FROM hails WHERE id = ?", hail_id, as: Int64
      ).should eq(1_i64)
      api.store.permanent_metadata_usage.should eq(6)
    end
  end

  it "charges transitioning relationships until cleanup physically removes them" do
    TinrelaySpec.with_server(permanent_metadata_limit: 8_i64) do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit(root, origin, "beta")
      TinrelaySpec.connect(root, alpha, beta)

      alpha.close_contact("beta").should eq(2)
      api.store.permanent_metadata_usage.should eq(8)

      api.store.cleanup(Time.utc.to_unix + Tinrelay::FALLBACK_LIFETIME_SECONDS + 1)

      api.database.db.scalar("SELECT COUNT(*) FROM relationships").should eq(0)
      api.store.permanent_metadata_usage.should eq(7)
    end
  end

  it "rejects a signed wrong-sized next owner key without consuming history" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      owner = alpha.keyring.owner
      next_public = Tinrelay::Crypto.b64(Bytes.new(40_000, 1_u8))
      rotation_bytes = Tinrelay::Canonical.fields(
        "tinrelay-owner-rotation-v1", "alpha", "2", next_public
      )
      prior_signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.sign(
          rotation_bytes, Tinrelay::Crypto.unb64(owner.key.secret_key)
        )
      )
      auth = Tinrelay::OwnerAuth.new("alpha", 1, 1_i64, Time.utc.to_unix)
      rotation = Tinrelay::OwnerRotation.new(2, next_public, prior_signature, auth)
      auth.signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.sign(
          auth.signing_bytes("owner.rotate", rotation.payload),
          Tinrelay::Crypto.unb64(owner.key.secret_key)
        )
      )
      headers = HTTP::Headers{
        "Content-Type"        => "application/json",
        "X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s,
      }

      response = HTTP::Client.post(
        "#{origin}/v1/owners/rotate", headers, rotation.to_json
      )

      response.status_code.should eq(400)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM ship_owner_keys WHERE ship = 'alpha'"
      ).as(Int64).should eq(1)
    end
  end

  it "bounds the operator setting to the identity-response contract" do
    root = TinrelaySpec.temporary_root
    database = Tinrelay::Database.new(File.join(root, "capacity.db"))
    begin
      expect_raises(Tinrelay::Invalid) { Tinrelay::Store.new(database, 0_i64) }
      expect_raises(Tinrelay::Invalid) do
        Tinrelay::Store.new(
          database, Tinrelay::MAX_PERMANENT_METADATA_LIMIT + 1
        )
      end
    ensure
      database.close
      FileUtils.rm_r(root)
    end
  end

  it "reads a valid identity history beyond the ordinary response ceiling" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      owner = alpha.keyring.owner.key
      previous_secret = Tinrelay::Crypto.unb64(owner.secret_key)

      api.database.db.transaction do |transaction|
        connection = transaction.connection
        2.upto(300) do |generation|
          keys = Tinrelay::Crypto.signing_keypair
          encoded = Tinrelay::Crypto.b64(keys.public_key)
          rotation = Tinrelay::Canonical.fields(
            "tinrelay-owner-rotation-v1", "alpha", generation.to_s, encoded
          )
          signature = Tinrelay::Crypto.sign(rotation, previous_secret)
          connection.exec(
            "UPDATE ship_owner_keys SET state = 'rotated', revoked_at = 0 " +
            "WHERE ship = 'alpha' AND state = 'active'"
          )
          connection.exec(
            <<-SQL, generation, keys.public_key, signature
              INSERT INTO ship_owner_keys(
                ship, generation, public_key, state, valid_from,
                authorization_signature
              ) VALUES ('alpha', ?, ?, 'active', 0, ?)
            SQL
          )
          previous_secret = keys.secret_key
        end
        connection.exec("UPDATE ships SET admin_generation = 299 WHERE name = 'alpha'")
      end

      card = alpha.who("alpha")
      card.bytesize.should be > Tinrelay::Remote::MAX_RESPONSE_BYTES
      card.bytesize.to_i64.should be < Tinrelay::MAX_IDENTITY_RESPONSE_BYTES
      JSON.parse(card)["owner_keys"].as_a.size.should eq(300)
    end
  end
end
