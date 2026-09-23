require "../spec_helper"

describe Tinrelay::LocalPaths do
  it "derives every private path from one validated ship selector" do
    paths = Tinrelay::LocalPaths.new("harbor", "/home/caller")

    config = File.join("/home/caller", ".config", "tinrelay", "harbor")
    data = File.join("/home/caller", ".local", "share", "tinrelay", "harbor")

    paths.keyring.should eq(File.join(config, "keyring"))
    paths.owner_key.should eq(File.join(config, "owner-key"))
    paths.outgoing_observer.should eq(
      File.join(config, "outgoing-observer.json")
    )
    paths.spool.should eq(File.join(data, "inbox"))
    paths.outbox.should eq(File.join(data, "outbox"))
    paths.outgoing.should eq(File.join(data, "outgoing"))
    paths.codex_addresses.should eq(File.join(config, "codex-addresses.json"))
    paths.local_delivery_lock.should eq(File.join(data, "inbox", "local-delivery.lock"))
    paths.pending_target.should eq(
      File.join("/home/caller", ".local", "share", "tinrelay-codex-bridge",
        "pending", "harbor.json")
    )
  end

  it "rejects a ship name before using it as a path component" do
    expect_raises(Tinrelay::Invalid, "invalid ship name") do
      Tinrelay::LocalPaths.new("../harbor", "/home/caller")
    end
  end
end
