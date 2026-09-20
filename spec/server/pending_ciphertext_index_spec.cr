require "../spec_helper"

module TinrelayPendingCiphertextIndexSpec
  def self.build_schema_002(path : String) : Nil
    database = DB.open("sqlite3://#{URI.encode_path(path)}?foreign_keys=on")
    database.exec(
      "CREATE TABLE schema_migrations " +
      "(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL) STRICT"
    )
    Tinrelay::Database::MIGRATIONS.first(2).each do |version, sql|
      sql.split(';').each do |statement|
        statement = statement.strip
        database.exec(statement) unless statement.empty?
      end
      database.exec(
        "INSERT INTO schema_migrations(version, applied_at) VALUES (?, 1)", version
      )
    end

    %w[sender recipient].each do |ship|
      database.exec(
        "INSERT INTO ships(name, claimed_at, state) VALUES (?, 1, 'active')", ship
      )
      database.exec(
        <<-SQL, ship
          INSERT INTO ship_owner_keys(
            ship, generation, public_key, state, valid_from
          ) VALUES (?, 1, X'01', 'active', 1)
        SQL
      )
      database.exec(
        <<-SQL, ship
          INSERT INTO ship_radio_keys(
            ship, generation, signing_public_key, encryption_public_key,
            state, issued_at, owner_generation, owner_signature
          ) VALUES (?, 1, X'01', X'01', 'active', 1, 1, X'01')
        SQL
      )
    end

    pending_sql = <<-SQL
        INSERT INTO transmissions(
          id, sender_ship, sender_signing_generation,
          recipient_ship, recipient_encryption_generation,
          created_at, expires_at, accepted_at, state,
          ciphertext, signature, envelope_digest
        ) VALUES (?, 'sender', 1, 'recipient', 1, ?, ?, ?, 'pending', ?, X'01', X'01')
      SQL
    256.times do |index|
      ciphertext_bytes = index.even? ? 17_408 : 512
      database.exec(
        pending_sql, "pending-#{index}", 1_000_000 + index,
        2_000_000 + index, 1_000_000 + index,
        Bytes.new(ciphertext_bytes, 1_u8)
      )
    end
    collected_sql = <<-SQL
        INSERT INTO transmissions(
          id, sender_ship, sender_signing_generation,
          recipient_ship, recipient_encryption_generation,
          created_at, expires_at, accepted_at, state,
          ciphertext, signature, envelope_digest
        ) VALUES (?, 'sender', 1, 'recipient', 1, ?, ?, ?, 'collected', NULL, NULL, X'01')
      SQL
    64.times do |index|
      database.exec(
        collected_sql, "collected-#{index}", 1_000_000 + index,
        2_000_000 + index,
        1_000_000 + index
      )
    end
  ensure
    database.try(&.close)
  end
end

describe "the pending ciphertext metrics index" do
  it "upgrades a populated schema and covers the pending-byte aggregate" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "service.db")
    TinrelayPendingCiphertextIndexSpec.build_schema_002(path)

    database = Tinrelay::Database.new(path)
    store = Tinrelay::Store.new(database)

    database.db.scalar("SELECT MAX(version) FROM schema_migrations").should eq(3_i64)
    store.metrics_snapshot(1_000_000_i64)[:ciphertext_bytes].should eq(2_293_760_i64)

    plan = database.db.query_all(
      "EXPLAIN QUERY PLAN " +
      "SELECT COALESCE(SUM(LENGTH(ciphertext)), 0) FROM transmissions " +
      "WHERE state = 'pending'",
      as: {Int64, Int64, Int64, String}
    ).map { |row| row[3] }
    plan.any?(&.includes?("USING COVERING INDEX pending_ciphertext_bytes")).should be_true
  ensure
    database.try(&.close)
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
