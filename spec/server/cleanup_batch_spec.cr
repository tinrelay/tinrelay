require "../spec_helper"

module TinrelayCleanupBatchSpec
  def self.seed(database : DB::Database, count : Int32) : Nil
    database.transaction do |transaction|
      connection = transaction.connection
      %w[sender recipient].each do |ship|
        connection.exec(
          "INSERT INTO ships(name, claimed_at, state) VALUES (?, 1, 'active')", ship
        )
        connection.exec(
          <<-SQL, ship
            INSERT INTO ship_owner_keys(
              ship, generation, public_key, state, valid_from
            ) VALUES (?, 1, X'01', 'active', 1)
          SQL
        )
        connection.exec(
          <<-SQL, ship
            INSERT INTO ship_radio_keys(
              ship, generation, signing_public_key, encryption_public_key,
              state, issued_at, owner_generation, owner_signature
            ) VALUES (?, 1, X'01', X'01', 'active', 1, 1, X'01')
          SQL
        )
      end

      count.times do |index|
        pending = index < Tinrelay::Store::CLEANUP_BATCH_SIZE
        id = "transmission-#{index}"
        state = pending ? "pending" : "collected"
        ciphertext = pending ? Bytes.new(Tinrelay::Store::MAX_CIPHERTEXT_BYTES, 1_u8) : nil
        signature = pending ? Bytes[1_u8] : nil
        connection.exec(
          <<-SQL, id, state, ciphertext, signature
            INSERT INTO transmissions(
              id, sender_ship, sender_signing_generation,
              recipient_ship, recipient_encryption_generation,
              created_at, expires_at, accepted_at, state,
              ciphertext, signature, envelope_digest
            ) VALUES (?, 'sender', 1, 'recipient', 1, 1, 2, 1, ?, ?, ?, X'01')
          SQL
        )
      end
    end
  end
end

describe "bounded transmission cleanup" do
  it "releases the writer boundary between fixed-size expiry batches" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "service.db")
    database = Tinrelay::Database.new(path, 2)
    store = Tinrelay::Store.new(database)
    batch_size = Tinrelay::Store::CLEANUP_BATCH_SIZE
    TinrelayCleanupBatchSpec.seed(database.db, batch_size + 1)

    first = store.cleanup(10_i64)
    first[:expired].should eq(batch_size)
    first[:deleted].should eq(batch_size)
    database.db.scalar("SELECT COUNT(*) FROM transmissions").should eq(1_i64)

    writer = Tinrelay::Database.new(path, 1)
    writer.db.exec(
      "INSERT INTO registration_events(accepted_at, source_bucket) VALUES (10, 'writer/32')"
    )
    writer.close

    second = store.cleanup(10_i64)
    second[:expired].should eq(0)
    second[:deleted].should eq(1)
    database.db.scalar("SELECT COUNT(*) FROM transmissions").should eq(0_i64)
    database.db.scalar("SELECT COUNT(*) FROM registration_events").should eq(1_i64)
  ensure
    writer.try(&.close)
    database.try(&.close)
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
