require "./spec_helper"

module TinrelayRateLimitExclusionSpec
  def self.write_config(path : String, exclude : Array(String)) : Nil
    File.write(path, {
      site: {
        site_name: "TinRelay", base_url: "https://tinrelay.space",
        wordmark: "Tin Relay", art_manifest_path: nil,
      },
      registration: {
        exclude: exclude,
      },
    }.to_json)
  end

  def self.with_server(exclude = [] of String, &)
    root = TinrelaySpec.temporary_root
    path = File.join(root, "tinrelayd.json")
    write_config(path, exclude)
    config = Tinrelay::ServerConfig.new(
      "127.0.0.1", 0, File.join(root, "service.db"),
      File.expand_path("../templates/common-bootstrap.md", __DIR__),
      "https://example.test/tinrelay.git", System.cpu_count,
      Tinrelay::DEFAULT_PERMANENT_METADATA_LIMIT, path
    )
    api = Tinrelay::API.new(config)
    server = HTTP::Server.new(api.handler)
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    begin
      yield root, "http://127.0.0.1:#{address.port}", api, path
    ensure
      server.close
      api.close
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  def self.reload(api : Tinrelay::API, path : String,
                  exclude : Array(String)) : Nil
    write_config(path, exclude)
    api.reload_configuration
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

  def self.seed_radio_limit(api : Tinrelay::API, client : Tinrelay::Client,
                            owner_generation : Int32,
                            now : Int64) : Int32
    ship = client.keyring.data.ship
    radio = client.keyring.data.radio!
    api.database.db.transaction do |transaction|
      connection = transaction.connection
      connection.exec(
        "UPDATE ship_radio_keys SET state = 'rotated', revoked_at = ? " +
        "WHERE ship = ? AND generation = 1",
        now - 1, ship
      )
      (2..Tinrelay::Store::MAX_RADIO_RETUNES_PER_DAY).each do |generation|
        connection.exec(
          "INSERT INTO ship_radio_keys(" +
          "ship, generation, signing_public_key, encryption_public_key, " +
          "state, issued_at, owner_generation, owner_signature, revoked_at" +
          ") VALUES (?, ?, ?, ?, 'rotated', 0, ?, ?, ?)",
          ship, generation, Tinrelay::Crypto.signing_keypair.public_key,
          Tinrelay::Crypto.box_keypair.public_key, owner_generation,
          Bytes.new(Tinrelay::Crypto::SIGNATURE_BYTES), now - 1
        )
      end
      active_generation = Tinrelay::Store::MAX_RADIO_RETUNES_PER_DAY + 1
      owner = client.keyring.owner.key
      certificate = Tinrelay::ShipRadioCertificate.new(
        ship, active_generation, radio.signing.public_key,
        radio.encryption.public_key, now, owner_generation
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
        ") VALUES (?, ?, ?, ?, 'active', ?, ?, ?)",
        ship, active_generation,
        Tinrelay::Crypto.unb64(radio.signing.public_key),
        Tinrelay::Crypto.unb64(radio.encryption.public_key), now,
        owner_generation, Tinrelay::Crypto.unb64(certificate.owner_signature)
      )
      active_generation
    end.not_nil!.to_i
  end

  def self.relationship_close(client : Tinrelay::Client,
                              peer : String, radio_generation : Int32,
                              owner_generation : Int32,
                              admin_generation : Int64,
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
    request = Tinrelay::RelationshipClose.new(
      peer, [] of String, certificate, prior_signature, auth
    )
    auth.signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        auth.signing_bytes("relationship.close", request.payload),
        Tinrelay::Crypto.unb64(owner.secret_key)
      )
    )
    request
  end
end

describe "authenticated ship rate-limit exclusions" do
  it "adds and removes transmission and hail exclusions atomically" do
    TinrelayRateLimitExclusionSpec.with_server(["alpha"]) do |root, origin, api, path|
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(0_i64)
      api.runtime_snapshot.rate_limit_excluded?("alpha").should be_true
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit_contact(root, origin, "beta", alpha)
      gamma = TinrelaySpec.admit(root, origin, "gamma")
      delta = TinrelaySpec.admit(root, origin, "delta")

      while api.transmission_buckets.admit("127.0.0.1/32", 1).nil?
      end
      Tinrelay::Store::MAX_HAILS_PER_DAY.times do
        api.hail_window.allow?("alpha").should be_true
      end

      transmission = alpha.send("steward@beta", "excluded transmission")
      retry_outbox = Tinrelay::Outbox.new(File.join(root, "excluded-retry-outbox"))
      retry_outbox.store(transmission)
      alpha.retry(retry_outbox, transmission.transmission_id)
      retry_outbox.list.should be_empty
      hail = alpha.hail("gamma")
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?",
        transmission.transmission_id
      ).as(Int64).should eq(1_i64)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM hails WHERE id = ?", hail.hail_id
      ).as(Int64).should eq(1_i64)

      TinrelayRateLimitExclusionSpec.reload(api, path, [] of String)
      now = Time.instant
      while api.transmission_buckets.admit("127.0.0.1/32", 1, now).nil?
      end
      limited = expect_raises(Tinrelay::TransmissionLimited) do
        alpha.send("steward@beta", "ordinary window applies again")
      end
      limited.retry_after_seconds.should be > 0
      limited.sender_ship.should eq("alpha")
      outbox = Tinrelay::Outbox.new("#{alpha.keyring.path}.outbox")
      outbox.list.map(&.transmission_id).should contain(limited.transmission_id)
      limited_hail = alpha.hail("delta")
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", limited.transmission_id
      ).as(Int64).should eq(0_i64)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM hails WHERE id = ?", limited_hail.hail_id
      ).as(Int64).should eq(0_i64)
    end
  end

  it "bypasses only owner and radio rolling windows after authentication" do
    TinrelayRateLimitExclusionSpec.with_server do |root, origin, api, path|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit(root, origin, "beta")
      TinrelaySpec.connect(root, alpha, beta)

      Tinrelay::Store::MAX_OWNER_ROTATIONS_PER_DAY.times do
        alpha.rotate_owner
      end
      TinrelayRateLimitExclusionSpec.reload(api, path, ["alpha"])
      alpha.rotate_owner.should eq(Tinrelay::Store::MAX_OWNER_ROTATIONS_PER_DAY + 2)

      TinrelayRateLimitExclusionSpec.reload(api, path, [] of String)
      expect_raises(Tinrelay::RotationLimited) { alpha.rotate_owner }
      TinrelayRateLimitExclusionSpec.reload(api, path, ["alpha"])

      now = Time.utc.to_unix
      owner_generation = alpha.keyring.data.owner_generation
      radio_generation = TinrelayRateLimitExclusionSpec.seed_radio_limit(
        api, alpha, owner_generation, now
      )
      request = TinrelayRateLimitExclusionSpec.relationship_close(
        alpha, "beta", radio_generation,
        owner_generation,
        api.database.db.scalar(
          "SELECT admin_generation FROM ships WHERE name = 'alpha'"
        ).as(Int64) + 1,
        now
      )
      forged = Tinrelay::RelationshipClose.from_json(request.to_json)
      forged.auth.signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.random(Tinrelay::Crypto::SIGNATURE_BYTES)
      )
      TinrelayRateLimitExclusionSpec.post(
        origin, "/v1/relationships/close", forged.to_json
      ).status_code.should eq(401)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM ship_radio_keys WHERE ship = 'alpha'"
      ).as(Int64).should eq(radio_generation.to_i64)

      response = TinrelayRateLimitExclusionSpec.post(
        origin, "/v1/relationships/close", request.to_json
      )
      response.status_code.should eq(200)
    end
  end
end
