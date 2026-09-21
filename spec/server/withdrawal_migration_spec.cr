require "../spec_helper"

module TinrelayWithdrawalMigrationSpec
  def self.build_schema_003(path : String) : Nil
    database = DB.open("sqlite3://#{URI.encode_path(path)}?foreign_keys=on")
    database.exec(
      "CREATE TABLE schema_migrations " +
      "(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL) STRICT"
    )
    Tinrelay::Database::MIGRATIONS.first(3).each do |version, sql|
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

    insert = <<-SQL
        INSERT INTO transmissions(
          id, sender_ship, sender_signing_generation,
          recipient_ship, recipient_encryption_generation,
          created_at, expires_at, accepted_at, state,
          ciphertext, signature, envelope_digest
        ) VALUES (?, 'sender', 1, 'recipient', 1, 1, 10, 2, ?, ?, ?, ?)
      SQL
    database.exec(insert, "pending", "pending", Bytes[1_u8], Bytes[2_u8], Bytes[3_u8])
    database.exec(insert, "collected", "collected", nil, nil, Bytes[4_u8])
  ensure
    database.try(&.close)
  end
end

describe "the withdrawn transmission migration" do
  it "preserves populated rows, foreign keys, and all transmission indexes" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "service.db")
    TinrelayWithdrawalMigrationSpec.build_schema_003(path)

    database = Tinrelay::Database.new(path)
    database.db.scalar("SELECT MAX(version) FROM schema_migrations").should eq(4_i64)
    database.db.query_all(
      "SELECT id, state, ciphertext, signature, envelope_digest " +
      "FROM transmissions ORDER BY id",
      as: {String, String, Bytes?, Bytes?, Bytes}
    ).should eq([
      {"collected", "collected", nil, nil, Bytes[4_u8]},
      {"pending", "pending", Bytes[1_u8], Bytes[2_u8], Bytes[3_u8]},
    ])
    database.db.query_all(
      "SELECT name FROM sqlite_schema WHERE type = 'index' " +
      "AND tbl_name = 'transmissions' AND sql IS NOT NULL ORDER BY name",
      as: String
    ).should eq(%w[pending_ciphertext_bytes pending_delivery transmissions_cleanup])
    database.db.query_all("PRAGMA foreign_key_check", as: {String, Int64, String, Int64})
      .should be_empty

    database.db.exec(
      "UPDATE transmissions SET state = 'withdrawn', ciphertext = NULL, " +
      "signature = NULL WHERE id = 'pending'"
    )
    database.db.query_one(
      "SELECT state, ciphertext, signature FROM transmissions WHERE id = 'pending'",
      as: {String, Bytes?, Bytes?}
    ).should eq({"withdrawn", nil, nil})
  ensure
    database.try(&.close)
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
