require "sqlite3"
require "json"

# Synthetic populated v3 state for the scratch-image upgrade proof. No ship keys or bodies.
mode, path = ARGV
database = DB.open("sqlite3://#{URI.encode_path(path)}?foreign_keys=on")

if mode == "seed"
  database.exec(
    "CREATE TABLE schema_migrations " +
    "(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL) STRICT"
  )
  [
    {{ read_file("sql/migrations/001_initial.sql") }},
    {{ read_file("sql/migrations/002_registration_events.sql") }},
    {{ read_file("sql/migrations/003_pending_ciphertext_bytes.sql") }},
  ].each_with_index do |sql, index|
    sql.split(';').each do |statement|
      database.exec(statement) unless statement.strip.empty?
    end
    database.exec("INSERT INTO schema_migrations VALUES (?, 1)", index + 1)
  end
  database.exec(<<-SQL)
    WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<12)
    INSERT INTO ships(name, claimed_at, state) SELECT 'fixture-'||i, 1, 'active' FROM n
    SQL
  database.exec(<<-SQL)
    INSERT INTO ship_owner_keys(ship, generation, public_key, state, valid_from)
    SELECT name, 1, X'01', 'active', 1 FROM ships
    SQL
  database.exec(<<-SQL)
    INSERT INTO ship_radio_keys(
      ship, generation, signing_public_key, encryption_public_key,
      state, issued_at, owner_generation, owner_signature
    ) SELECT name, 1, X'01', X'02', 'active', 1, 1, X'03' FROM ships
    SQL
  database.exec(<<-SQL)
    INSERT INTO relationships(ship_a, ship_b, state)
    VALUES ('fixture-1', 'fixture-2', 'active'), ('fixture-3', 'fixture-4', 'active')
    SQL
  database.exec(<<-SQL)
    WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<179)
    INSERT INTO transmissions(
      id, sender_ship, sender_signing_generation, recipient_ship,
      recipient_encryption_generation, created_at, expires_at, accepted_at,
      state, ciphertext, signature, envelope_digest
    ) SELECT 'fixture-transmission-'||i, 'fixture-1', 1, 'fixture-2', 1,
      1, 4102444800, 1, 'collected', NULL, NULL, X'04' FROM n
    SQL
elsif mode != "verify"
  raise "expected seed or verify"
end

# Compare every stored field, index definition, and foreign-key definition, not just row counts.
snapshot = {} of String => Array(Array(String))
tables = database.query_all(
  "SELECT name FROM sqlite_schema WHERE type='table' AND name!='schema_migrations' ORDER BY name",
  as: String
)
queries = tables.map { |table| {table, "SELECT * FROM #{table} ORDER BY rowid"} }
queries << {
  "indexes", "SELECT name, tbl_name, sql FROM sqlite_schema WHERE type='index' ORDER BY name",
}
queries << {"migrations", "SELECT * FROM schema_migrations WHERE version<=3 ORDER BY version"}
tables.each do |table|
  queries << {"#{table}:foreign_keys", "PRAGMA foreign_key_list(#{table})"}
  queries << {"#{table}:columns", "PRAGMA table_info(#{table})"}
end
database.query_all(
  "SELECT name FROM sqlite_schema WHERE type='index' ORDER BY name", as: String
).each do |index|
  queries << {"#{index}:columns", "PRAGMA index_xinfo(#{index})"}
end
queries.each do |name, sql|
  records = [] of Array(String)
  database.query(sql) do |rows|
    rows.each do
      records << Array.new(rows.column_count) do
        value = rows.read
        value = value.split.join(" ") if name == "indexes" && value.is_a?(String)
        value.inspect
      end
    end
  end
  snapshot[name] = records
end
expected = "#{path}.expected.json"
if mode == "seed"
  File.write(expected, snapshot.to_json)
else
  raise "migration changed retained state" unless File.read(expected) == snapshot.to_json
  raise "schema version is not 4" unless database.scalar(
                                           "SELECT MAX(version) FROM schema_migrations"
                                         ) == 4_i64
  raise "integrity failure" unless database.scalar("PRAGMA integrity_check") == "ok"
  database.query("PRAGMA foreign_key_check") do |rows|
    raise "foreign-key failure" if rows.move_next
  end
  puts "Populated schema 003 to 004 retained all rows, indexes, and foreign keys."
end
database.close
