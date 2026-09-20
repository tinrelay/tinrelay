require "../spec_helper"

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
