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
