module Tinrelay
  class Database
    MIGRATIONS = [
      {1, {{ read_file("sql/migrations/001_initial.sql") }}},
      {2, {{ read_file("sql/migrations/002_registration_events.sql") }}},
      {3, {{ read_file("sql/migrations/003_pending_ciphertext_bytes.sql") }}},
    ]

    getter db : DB::Database
    getter path : String

    def initialize(@path : String, max_connections : Int32 = System.cpu_count)
      raise Invalid.new("database connection count must be positive") unless max_connections > 0
      directory = File.dirname(path)
      if directory != "." && !Dir.exists?(directory)
        Dir.mkdir_p(directory, mode: 0o700)
        File.chmod(directory, 0o700)
      end
      uri = "sqlite3://#{URI.encode_path(path)}?" +
            "journal_mode=wal&" +
            "synchronous=full&" +
            "busy_timeout=5000&" +
            "foreign_keys=on&" +
            "max_pool_size=#{max_connections}"
      @db = DB.open(uri)
      File.chmod(path, 0o600) if File.exists?(path)
      configure
      migrate
    end

    def close : Nil
      db.close
    end

    # Apparent bytes currently occupied by SQLite's main database, WAL, and
    # shared-memory files. This is a cheap operator-facing storage reading, not
    # an estimate of live records or filesystem-allocated blocks.
    def files_bytes : Int64
      ["", "-wal", "-shm"].sum do |suffix|
        File.info?("#{path}#{suffix}").try(&.size) || 0_i64
      end
    end

    def migrate : Nil
      db.exec(
        "CREATE TABLE IF NOT EXISTS schema_migrations " +
        "(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL) STRICT"
      )
      current = db.scalar("SELECT COALESCE(MAX(version), 0) FROM schema_migrations").as(Int64).to_i
      raise Error.new("database schema is newer than this binary") if current > MIGRATIONS.last[0]
      MIGRATIONS.each do |version, sql|
        next if version <= current
        db.transaction do |transaction|
          sql.split(';').each do |statement|
            statement = statement.strip
            transaction.connection.exec(statement) unless statement.empty?
          end
          transaction.connection.exec(
            "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)",
            version,
            Time.utc.to_unix
          )
        end
      end
    end

    private def configure : Nil
      unless db.scalar("PRAGMA journal_mode").as(String).downcase == "wal"
        raise Error.new("SQLite WAL configuration failed")
      end
      unless db.scalar("PRAGMA foreign_keys").as(Int64) == 1
        raise Error.new("SQLite foreign keys are disabled")
      end
    end
  end
end
