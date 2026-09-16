require "./spec_helper"

describe "local radio status" do
  it "reads one pending or routed record without scanning or mutating the spool" do
    root = TinrelaySpec.temporary_root
    spool_root = File.join(root, "inbox")
    spool = Tinrelay::Spool.new(spool_root)
    record = Tinrelay::RejectedTransmissionSpoolRecord.new(
      local_id: "tr_0123456789abcdef0123456789abcdef",
      received_at: 10_i64,
      relay_transmission_id: "11111111-1111-4111-8111-111111111111",
      rejection_reason: "unusable_envelope"
    )
    Tinrelay::AtomicPrivateFile.write(
      File.join(spool.pending, "#{record.local_id}.json"),
      record.to_pretty_json + "\n"
    )
    File.write(File.join(spool.routed, "tr_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json"), "corrupt")
    {% if flag?(:win32) %}
      TinrelaySpec::WindowsAcl.permissive(spool_root)
    {% elsif flag?(:darwin) || flag?(:linux) %}
      File.chmod(spool_root, 0o750)
    {% else %}
      {% raise "TinRelay specs do not support this platform" %}
    {% end %}

    reader = Tinrelay::Spool.open_existing(spool_root)
    reader.status(record.local_id).should eq({
      state: "pending", local_id: record.local_id,
      kind: "rejected_transmission",
    })
    {% if flag?(:win32) %}
      Tinrelay::PrivateStorage.private?(spool_root).should be_false
    {% elsif flag?(:darwin) || flag?(:linux) %}
      (File.info(spool_root).permissions.value & 0o777).should eq(0o750)
    {% else %}
      {% raise "TinRelay specs do not support this platform" %}
    {% end %}

    original = File.read(File.join(spool.pending, "#{record.local_id}.json"))
    spool.routed(record.local_id)
    reader.status(record.local_id).should eq({
      state: "routed", local_id: record.local_id,
      kind: "rejected_transmission",
    })
    File.exists?(File.join(spool.pending, "#{record.local_id}.json")).should be_false
    File.read(File.join(spool.routed, "#{record.local_id}.json")).should eq(original)
    spool.routed(record.local_id).routed.should be_true
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "does not create a missing spool and reports missing or corrupt records" do
    root = TinrelaySpec.temporary_root
    missing = File.join(root, "missing")
    reader = Tinrelay::Spool.open_existing(missing)

    expect_raises(Tinrelay::NotFound, "inbox record not found") do
      reader.status("tr_0123456789abcdef0123456789abcdef")
    end
    Dir.exists?(missing).should be_false

    spool = Tinrelay::Spool.new(File.join(root, "inbox"))
    corrupt_id = "tr_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    File.write(File.join(spool.pending, "#{corrupt_id}.json"), "not json")
    expect_raises(Tinrelay::Error, "inbox record is corrupt: #{corrupt_id}.json") do
      Tinrelay::Spool.open_existing(spool.root).status(corrupt_id)
    end
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "rejects an embedded ID mismatch before consulting another routed record" do
    root = TinrelaySpec.temporary_root
    spool = Tinrelay::Spool.new(File.join(root, "inbox"))
    requested_id = "tr_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    embedded_id = "tr_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    record = Tinrelay::RejectedTransmissionSpoolRecord.new(
      local_id: embedded_id,
      received_at: 10_i64,
      relay_transmission_id: "11111111-1111-4111-8111-111111111111",
      rejection_reason: "unusable_envelope"
    )
    record_path = File.join(spool.pending, "#{requested_id}.json")
    routed_path = File.join(spool.routed, "#{embedded_id}.json")
    Tinrelay::AtomicPrivateFile.write(record_path, record.to_pretty_json + "\n")
    Tinrelay::AtomicPrivateFile.write(routed_path, record.to_pretty_json + "\n")
    record_bytes = File.read(record_path)
    routed_bytes = File.read(routed_path)

    expect_raises(Tinrelay::Error, "inbox record id does not match requested id") do
      Tinrelay::Spool.open_existing(spool.root).status(requested_id)
    end
    File.read(record_path).should eq(record_bytes)
    File.read(routed_path).should eq(routed_bytes)
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "rejects a traversal-shaped routed ID without changing the spool" do
    root = TinrelaySpec.temporary_root
    spool = Tinrelay::Spool.new(File.join(root, "inbox"))
    canary = File.join(spool.root, "escape.json")
    File.write(canary, "must remain unread and unchanged")

    expect_raises(Tinrelay::Invalid, "invalid local inbox id") do
      spool.routed("../escape")
    end
    File.read(canary).should eq("must remain unread and unchanged")
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
