require "../spec_helper"

module TinrelayDatabaseSchemaSpec
  def self.columns(database : Tinrelay::Database, table : String) : Array(String)
    names = [] of String
    database.db.query("PRAGMA table_info(#{table})") do |rows|
      rows.each do
        rows.read(Int64)
        names << rows.read(String)
        rows.read(String)
        rows.read(Int64)
        rows.read(String?)
        rows.read(Int64)
      end
    end
    names
  end
end

describe "the relay database schema" do
  it "uses memory for temporary storage on every pooled connection" do
    root = TinrelaySpec.temporary_root
    database = Tinrelay::Database.new(File.join(root, "temporary.db"), max_connections: 2)
    database.db.using_connection do |first|
      database.db.using_connection do |second|
        first.scalar("PRAGMA temp_store").should eq(2_i64)
        second.scalar("PRAGMA temp_store").should eq(2_i64)
        second.scalar("PRAGMA foreign_keys").should eq(1_i64)
        second.scalar("PRAGMA synchronous").should eq(2_i64)
        second.scalar("PRAGMA journal_mode").should eq("wal")
      end
    end
  ensure
    database.try(&.close)
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "stores only the protocol-owned fields for keys, hails, relationships, and transmissions" do
    root = TinrelaySpec.temporary_root
    database = Tinrelay::Database.new(File.join(root, "schema.db"))

    TinrelayDatabaseSchemaSpec.columns(database, "ship_owner_keys").should eq(%w(
      ship generation public_key state valid_from revoked_at authorization_signature
    ))
    TinrelayDatabaseSchemaSpec.columns(database, "ship_radio_keys").should eq(%w(
      ship generation signing_public_key encryption_public_key state issued_at
      owner_generation owner_signature prior_radio_signature revoked_at
    ))
    TinrelayDatabaseSchemaSpec.columns(database, "hails").should eq(%w(
      id sender_ship sender_signing_generation recipient_ship created_at
      expires_at signature collected_at allowed_at
    ))
    TinrelayDatabaseSchemaSpec.columns(database, "relationships").should eq(%w(
      ship_a ship_b state transition_until
    ))
    TinrelayDatabaseSchemaSpec.columns(database, "transmissions").should eq(%w(
      id sender_ship sender_signing_generation recipient_ship
      recipient_encryption_generation created_at expires_at accepted_at state
      ciphertext signature envelope_digest
    ))
  ensure
    database.try(&.close)
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
