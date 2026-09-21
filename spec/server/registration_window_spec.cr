require "../spec_helper"

module TinrelayRegistrationWindowSpec
  HOUR = 60_i64 * 60
  DAY  = 24_i64 * HOUR
  OPEN = Tinrelay::RegistrationAllowances.new(100, 100, 100, 100)

  def self.with_store(connections = 1, metadata_limit = 25_000_i64, &)
    root = TinrelaySpec.temporary_root
    database = Tinrelay::Database.new(File.join(root, "service.db"), connections)
    store = Tinrelay::Store.new(database, metadata_limit)
    yield store
  ensure
    database.try(&.close)
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  def self.prepared(store : Tinrelay::Store, ship : String,
                    now = 1_000_000_i64) : Tinrelay::PreparedShipClaim
    owner = Tinrelay::Crypto.signing_keypair
    signing = Tinrelay::Crypto.signing_keypair
    encryption = Tinrelay::Crypto.box_keypair
    certificate = Tinrelay::ShipRadioCertificate.new(
      ship, 1, Tinrelay::Crypto.b64(signing.public_key),
      Tinrelay::Crypto.b64(encryption.public_key), now, 1
    )
    certificate.owner_signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(certificate.unsigned_bytes, owner.secret_key)
    )
    store.prepare_claim(Tinrelay::ShipClaim.new(
      ship, Tinrelay::Crypto.b64(owner.public_key), certificate
    ))
  end

  def self.claim(store : Tinrelay::Store, ship : String, bucket : String,
                 allowances = OPEN, now = 1_000_000_i64) : Nil
    store.claim(prepared(store, ship, now), bucket, allowances, -> { true }, now)
  end

  def self.seed(store : Tinrelay::Store, bucket : String, accepted_at : Int64) : Nil
    store.database.db.exec(
      "INSERT INTO registration_events(accepted_at, source_bucket) VALUES (?, ?)",
      accepted_at, bucket
    )
  end
end

describe "durable successful ship-registration windows" do
  it "upgrades schema 001 in place without fabricating historical events" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "upgrade.db")
    raw = DB.open("sqlite3://#{URI.encode_path(path)}?foreign_keys=on")
    raw.exec(
      "CREATE TABLE schema_migrations " +
      "(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL) STRICT"
    )
    Tinrelay::Database::MIGRATIONS[0][1].split(';').each do |statement|
      statement = statement.strip
      raw.exec(statement) unless statement.empty?
    end
    raw.exec("INSERT INTO schema_migrations(version, applied_at) VALUES (1, 1)")
    raw.exec("INSERT INTO ships(name, claimed_at, state) VALUES ('existing', 1, 'active')")
    raw.close

    database = Tinrelay::Database.new(path)
    database.db.scalar("SELECT MAX(version) FROM schema_migrations").should eq(4_i64)
    database.db.scalar("SELECT COUNT(*) FROM ships").should eq(1_i64)
    database.db.scalar("SELECT COUNT(*) FROM registration_events").should eq(0_i64)
    database.db.scalar(
      "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' " +
      "AND name IN ('registration_events_time', 'registration_events_source_time')"
    ).should eq(2_i64)
  ensure
    database.try(&.close)
    raw.try(&.close)
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "creates the ship, keys, and one minimal success event atomically" do
    TinrelayRegistrationWindowSpec.with_store do |store|
      TinrelayRegistrationWindowSpec.claim(
        store, "alpha", "192.0.2.8/32", now: 10_000_i64
      )

      store.database.db.query_one(
        "SELECT accepted_at, source_bucket FROM registration_events",
        as: {Int64, String}
      ).should eq({10_000_i64, "192.0.2.8/32"})
      store.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(1_i64)
      store.database.db.scalar("SELECT COUNT(*) FROM ship_owner_keys").should eq(1_i64)
      store.database.db.scalar("SELECT COUNT(*) FROM ship_radio_keys").should eq(1_i64)
    end
  end

  it "enforces each global and per-source hourly and daily window" do
    now = 100_000_i64
    cases = [
      {Tinrelay::RegistrationAllowances.new(1, 10, 10, 10), "other/32", now - 10_i64,
       "source/32", TinrelayRegistrationWindowSpec::HOUR - 10_i64},
      {Tinrelay::RegistrationAllowances.new(10, 1, 10, 10), "other/32", now - 7200_i64,
       "source/32", TinrelayRegistrationWindowSpec::DAY - 7200_i64},
      {Tinrelay::RegistrationAllowances.new(10, 10, 1, 10), "source/32", now - 10_i64,
       "source/32", TinrelayRegistrationWindowSpec::HOUR - 10_i64},
      {Tinrelay::RegistrationAllowances.new(10, 10, 10, 1), "source/32", now - 7200_i64,
       "source/32", TinrelayRegistrationWindowSpec::DAY - 7200_i64},
    ]

    cases.each_with_index do |test_case, index|
      allowances, event_bucket, accepted_at, claim_bucket, retry_after = test_case
      TinrelayRegistrationWindowSpec.with_store do |store|
        TinrelayRegistrationWindowSpec.seed(store, event_bucket, accepted_at)
        limited = expect_raises(Tinrelay::RegistrationLimited) do
          TinrelayRegistrationWindowSpec.claim(
            store, "limited-#{index}", claim_bucket, allowances, now
          )
        end
        limited.retry_after_seconds.should eq(retry_after)
        store.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(0_i64)
        store.database.db.scalar("SELECT COUNT(*) FROM registration_events").should eq(1_i64)
      end
    end
  end

  it "keeps source windows independent" do
    TinrelayRegistrationWindowSpec.with_store do |store|
      now = 100_000_i64
      allowances = Tinrelay::RegistrationAllowances.new(10, 10, 1, 1)
      TinrelayRegistrationWindowSpec.seed(store, "198.51.100.8/32", now - 1)

      TinrelayRegistrationWindowSpec.claim(
        store, "alpha", "192.0.2.8/32", allowances, now
      )
      store.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(1_i64)
      store.database.db.scalar("SELECT COUNT(*) FROM registration_events").should eq(2_i64)
    end
  end

  it "treats any zero allowance as administrative closure without writing" do
    TinrelayRegistrationWindowSpec.with_store do |store|
      allowances = Tinrelay::RegistrationAllowances.new(10, 10, 0, 10)
      expect_raises(Tinrelay::RegistrationUnavailable) do
        TinrelayRegistrationWindowSpec.claim(
          store, "closed", "192.0.2.8/32", allowances
        )
      end
      store.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(0_i64)
      store.database.db.scalar("SELECT COUNT(*) FROM registration_events").should eq(0_i64)
    end
  end

  it "uses each lowered window's reopening event and returns the latest delay" do
    TinrelayRegistrationWindowSpec.with_store do |store|
      now = 100_000_i64
      allowances = Tinrelay::RegistrationAllowances.new(3, 10, 2, 10)
      TinrelayRegistrationWindowSpec.seed(store, "other/32", now - 500)
      TinrelayRegistrationWindowSpec.seed(store, "source/32", now - 300)
      TinrelayRegistrationWindowSpec.seed(store, "source/32", now - 200)
      TinrelayRegistrationWindowSpec.seed(store, "source/32", now - 100)

      limited = expect_raises(Tinrelay::RegistrationLimited) do
        TinrelayRegistrationWindowSpec.claim(
          store, "alpha", "source/32", allowances, now
        )
      end
      limited.retry_after_seconds.should eq(TinrelayRegistrationWindowSpec::HOUR - 200)
      store.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(0_i64)
      store.database.db.scalar("SELECT COUNT(*) FROM registration_events").should eq(4_i64)
    end
  end

  it "expires the cutoff inclusively while retaining future-dated events" do
    TinrelayRegistrationWindowSpec.with_store do |store|
      now = 100_000_i64
      future = now + 60_i64
      allowances = Tinrelay::RegistrationAllowances.new(10, 1, 10, 10)
      TinrelayRegistrationWindowSpec.seed(
        store, "expired/32", now - TinrelayRegistrationWindowSpec::DAY
      )
      TinrelayRegistrationWindowSpec.seed(store, "future/32", future)

      limited = expect_raises(Tinrelay::RegistrationLimited) do
        TinrelayRegistrationWindowSpec.claim(
          store, "alpha", "source/32", allowances, now
        )
      end
      limited.retry_after_seconds.should eq(TinrelayRegistrationWindowSpec::DAY + 60_i64)
      accepted_at = store.database.db.query_all(
        "SELECT accepted_at FROM registration_events ORDER BY accepted_at", as: Int64
      )
      accepted_at.should eq([now - TinrelayRegistrationWindowSpec::DAY, future])

      later = future + TinrelayRegistrationWindowSpec::DAY
      TinrelayRegistrationWindowSpec.claim(
        store, "alpha", "source/32", allowances, later
      )
      store.database.db.query_one(
        "SELECT accepted_at FROM registration_events", as: Int64
      ).should eq(later)
    end
  end

  it "expires source events through periodic cleanup without another registration" do
    TinrelayRegistrationWindowSpec.with_store do |store|
      now = 100_000_i64
      TinrelayRegistrationWindowSpec.seed(
        store, "old/32", now - TinrelayRegistrationWindowSpec::DAY - 1
      )
      TinrelayRegistrationWindowSpec.seed(
        store, "boundary/32", now - TinrelayRegistrationWindowSpec::DAY
      )
      TinrelayRegistrationWindowSpec.seed(store, "current/32", now - 1)

      store.cleanup(now)

      store.database.db.query_all(
        "SELECT source_bucket FROM registration_events ORDER BY accepted_at",
        as: String
      ).should eq(["current/32"])
      store.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(0_i64)
    end
  end

  it "survives restart and does not oversubscribe concurrent claims" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "durable.db")
    allowances = Tinrelay::RegistrationAllowances.new(1, 1, 1, 1)
    database = Tinrelay::Database.new(path, 2)
    store = Tinrelay::Store.new(database)
    TinrelayRegistrationWindowSpec.claim(
      store, "first", "192.0.2.8/32", allowances, 100_000_i64
    )
    database.close

    database = Tinrelay::Database.new(path, 2)
    store = Tinrelay::Store.new(database)
    expect_raises(Tinrelay::RegistrationLimited) do
      TinrelayRegistrationWindowSpec.claim(
        store, "after-restart", "192.0.2.8/32", allowances, 100_001_i64
      )
    end
    database.db.exec("DELETE FROM registration_events")
    database.db.exec("DELETE FROM ship_radio_keys")
    database.db.exec("DELETE FROM ship_owner_keys")
    database.db.exec("DELETE FROM ships")

    results = Channel(Exception?).new(2)
    %w[alpha beta].each do |ship|
      prepared = TinrelayRegistrationWindowSpec.prepared(store, ship, 200_000_i64)
      spawn do
        begin
          store.claim(
            prepared, "192.0.2.8/32", allowances, -> { true }, 200_000_i64
          )
          results.send(nil)
        rescue ex
          results.send(ex)
        end
      end
    end
    outcomes = 2.times.map { TinrelaySpec.receive(results) }.to_a
    outcomes.count(&.nil?).should eq(1)
    outcomes.compact.first.should be_a(Tinrelay::RegistrationLimited)
    database.db.scalar("SELECT COUNT(*) FROM ships").should eq(1_i64)
    database.db.scalar("SELECT COUNT(*) FROM registration_events").should eq(1_i64)
  ensure
    database.try(&.close)
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
