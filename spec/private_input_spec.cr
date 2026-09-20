require "./spec_helper"
require "../src/tinrelay/client/private_input"

describe Tinrelay::PrivateInput do
  it "accepts owner-only files and protected stdin without retaining line endings" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "passphrase")
    File.write(path, "private-secret\n", perm: 0o600)
    Tinrelay::PrivateStorage.secure(path, 0o600)

    Tinrelay::PrivateInput.read(path, "passphrase").should eq("private-secret")
    Tinrelay::PrivateInput.read("-", "passphrase", IO::Memory.new("stdin-secret\n"))
      .should eq("stdin-secret")
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "rejects files readable outside the owner" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "passphrase")
    File.write(path, "exposed", perm: 0o644)

    expect_raises(Tinrelay::Invalid, "passphrase file must be private to the current user") do
      Tinrelay::PrivateInput.read(path, "passphrase")
    end
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
