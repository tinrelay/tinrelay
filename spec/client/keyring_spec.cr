require "../spec_helper"

describe Tinrelay::Keyring do
  it "creates one owner-authorized radio identity with matching private pairs" do
    owner_keys = Tinrelay::Crypto.signing_keypair
    owner = Tinrelay::StoredKeyPair.from_raw(owner_keys.public_key, owner_keys.secret_key)
    identity = Tinrelay::ShipRadioIdentity.create_signed(
      "alpha", 3, 2, owner, 1_700_000_000_i64
    )
    certificate = identity.certificate

    identity.generation.should eq(3)
    identity.owner_public_key.should eq(owner.public_key)
    certificate.ship.should eq("alpha")
    certificate.owner_generation.should eq(2)
    certificate.issued_at.should eq(1_700_000_000_i64)
    certificate.signing_public_key.should eq(identity.signing.public_key)
    certificate.encryption_public_key.should eq(identity.encryption.public_key)
    Tinrelay::Crypto.verify(
      certificate.unsigned_bytes,
      Tinrelay::Crypto.unb64(certificate.owner_signature), owner_keys.public_key
    ).should be_true
  end

  it "stores private keys directly in owner-only files" do
    root = TinrelaySpec.temporary_root
    directory = File.join(root, "keys")
    Dir.mkdir(directory, 0o755)
    path = File.join(directory, "keyring")
    keyring = Tinrelay::Keyring.create(path, "http://localhost:8787", "alpha")
    owner = keyring.owner

    File.read(path).should contain(keyring.data.radio!.signing.secret_key)
    File.read(keyring.owner_path).should contain(owner.key.secret_key)
    TinrelaySpec.assert_private_storage(directory, 0o700)
    TinrelaySpec.assert_private_storage(path, 0o600)
    TinrelaySpec.assert_private_storage(keyring.owner_path, 0o600)

    loaded = Tinrelay::Keyring.load(path)
    loaded.data.to_json.should eq(keyring.data.to_json)
    loaded.owner.to_json.should eq(owner.to_json)
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
