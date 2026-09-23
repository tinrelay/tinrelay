require "../spec_helper"

module TinrelayRateLimitExclusionSpec
  def self.write_config(path : String, exclude : Array(String)) : Nil
    File.write(path, {
      registration: {
        exclude: exclude,
      },
    }.to_json)
  end

  def self.with_server(exclude = [] of String, &)
    policy = Tinrelay::TinrelaydConfig.new(
      registration: Tinrelay::TinrelaydConfig::Registration.new(exclude: exclude)
    )
    TinrelaySpec.with_server(runtime_policy: policy) do |root, origin, api, path|
      yield root, origin, api, path.not_nil!
    end
  end

  def self.reload(api : Tinrelay::API, path : String,
                  exclude : Array(String)) : Nil
    write_config(path, exclude)
    api.reload_configuration
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
      paths = Tinrelay::LocalPaths.new("alpha", root)
      outgoing = Tinrelay::OutgoingStore.new(paths.outgoing, "alpha")
      limited = expect_raises(Tinrelay::TransmissionLimited) do
        alpha.send(
          "steward@beta", "ordinary window applies again", outgoing: outgoing
        )
      end
      limited.retry_after_seconds.should be > 0
      limited.sender_ship.should eq("alpha")
      outgoing.list_outbox.map(&.transmission_id).should contain(limited.transmission_id)
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
      revoked_at = Array(Int64?).new(Tinrelay::Store::MAX_RADIO_RETUNES_PER_DAY) { now - 1 }
      radio_generation = TinrelaySpec.seed_radio_history(
        api, alpha, owner_generation, revoked_at, now
      )
      request = TinrelaySpec.relationship_close(
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
      TinrelaySpec.post(
        origin, "/v1/relationships/close", forged.to_json
      ).status_code.should eq(401)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM ship_radio_keys WHERE ship = 'alpha'"
      ).as(Int64).should eq(radio_generation.to_i64)

      response = TinrelaySpec.post(
        origin, "/v1/relationships/close", request.to_json
      )
      response.status_code.should eq(200)
    end
  end
end
