require "./spec_helper"

describe Tinrelay::Keyring do
  it "stores private keys directly in owner-only files" do
    root = TinrelaySpec.temporary_root
    directory = File.join(root, "keys")
    Dir.mkdir(directory, 0o755)
    path = File.join(directory, "keyring")
    keyring = Tinrelay::Keyring.create(path, "http://localhost:8787", "alpha")
    owner = keyring.owner

    File.read(path).should contain(keyring.data.radio!.signing.secret_key)
    File.read(keyring.owner_path).should contain(owner.key.secret_key)
    (File.info(directory).permissions.value & 0o777).should eq(0o700)
    (File.info(path).permissions.value & 0o777).should eq(0o600)
    (File.info(keyring.owner_path).permissions.value & 0o777).should eq(0o600)

    loaded = Tinrelay::Keyring.load(path)
    loaded.data.to_json.should eq(keyring.data.to_json)
    loaded.owner.to_json.should eq(owner.to_json)
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "requires explicit migration before ordinary use of legacy encrypted files" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "keys", "keyring")
    keyring = Tinrelay::Keyring.create(path, "http://localhost:8787", "alpha")
    TinrelaySpec::LegacyKeyFiles.wrap(keyring, "legacy passphrase")

    expect_raises(Tinrelay::MigrationRequired, /tinrelay --ship SHIP migrate/) do
      Tinrelay::Keyring.load(path)
    end
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "migrates legacy files without changing ship identity and is safe to repeat" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "keys", "keyring")
    keyring = Tinrelay::Keyring.create(path, "http://localhost:8787", "alpha")
    expected_keyring = keyring.data.to_json
    expected_owner = keyring.owner.to_json
    TinrelaySpec::LegacyKeyFiles.wrap(keyring, "legacy passphrase")
    encrypted_keyring = File.read(path)
    encrypted_owner = File.read(keyring.owner_path)

    expect_raises(Tinrelay::Unauthorized) do
      Tinrelay::Keyring.migrate(path, "wrong passphrase")
    end
    File.read(path).should eq(encrypted_keyring)
    File.read(keyring.owner_path).should eq(encrypted_owner)

    Tinrelay::Keyring.migration_required?(path).should be_true
    Tinrelay::Keyring.migrate(path, "legacy passphrase").should be_true
    Tinrelay::Keyring.migration_required?(path).should be_false
    Tinrelay::Keyring.load(path).data.to_json.should eq(expected_keyring)
    Tinrelay::Keyring.load(path).owner.to_json.should eq(expected_owner)
    Tinrelay::Keyring.migrate(path, nil).should be_false
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "resumes when either legacy file remains" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "keys", "keyring")
    keyring = Tinrelay::Keyring.create(path, "http://localhost:8787", "alpha")
    owner_plaintext = File.read(keyring.owner_path)
    TinrelaySpec::LegacyKeyFiles.wrap(keyring, "legacy passphrase")

    Tinrelay::AtomicPrivateFile.write(keyring.owner_path, owner_plaintext)
    Tinrelay::Keyring.migrate(path, "legacy passphrase").should be_true
    Tinrelay::Keyring.load(path).owner.ship.should eq("alpha")

    keyring_plaintext = File.read(path)
    TinrelaySpec::LegacyKeyFiles.wrap(keyring, "legacy passphrase")
    Tinrelay::AtomicPrivateFile.write(path, keyring_plaintext)
    Tinrelay::Keyring.migrate(path, "legacy passphrase").should be_true
    Tinrelay::Keyring.load(path).owner.ship.should eq("alpha")
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "rejects an unsupported legacy KDF without changing either file" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "keys", "keyring")
    keyring = Tinrelay::Keyring.create(path, "http://localhost:8787", "alpha")
    TinrelaySpec::LegacyKeyFiles.wrap(keyring, "legacy passphrase")
    envelope = JSON.parse(File.read(path))
    envelope.as_h["kdf"] = JSON::Any.new("scrypt")
    Tinrelay::AtomicPrivateFile.write(path, envelope.to_pretty_json + '\n')
    before_keyring = File.read(path)
    before_owner = File.read(keyring.owner_path)

    expect_raises(Tinrelay::Invalid, "unsupported keyring KDF profile") do
      Tinrelay::Keyring.migrate(path, "legacy passphrase")
    end
    File.read(path).should eq(before_keyring)
    File.read(keyring.owner_path).should eq(before_owner)
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
