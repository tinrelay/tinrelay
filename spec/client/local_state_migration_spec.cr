require "../spec_helper"

class MigrationSequenceRemote < Tinrelay::Remote
  def initialize(origin : String, @envelope : Tinrelay::SignedRelayEnvelope)
    super(origin)
  end

  def post(path : String, body : String) : String
    case path
    when "/v1/radio/wait"
      Tinrelay::RadioWaitResponse.new(envelope: @envelope).to_json
    when "/v1/transmissions/ack"
      %({"state":"acknowledged"})
    else
      super
    end
  end
end

module TinrelayLocalStateMigrationSpec
  def self.legacy_id(kind : String, source : String) : String
    digest = Digest::SHA256.hexdigest(
      Tinrelay::Canonical.fields("tinrelay-local-evidence-v1", kind, source)
    )
    "tr_#{digest[0, 32]}"
  end

  def self.downgrade(spool : Tinrelay::Spool, state : String,
                     record : Tinrelay::SpoolRecord) : Tuple(String, String)
    value = JSON.parse(record.to_json).as_h
    source = case record
             when Tinrelay::RejectedTransmissionSpoolRecord
               "#{record.transmission_id}:#{record.rejection_reason}"
             else
               record.source_id
             end
    legacy_kind = record.kind == "rejected_transmission" ? "rejection" : record.kind
    old_id = legacy_id(legacy_kind, source)
    value["format"] = JSON::Any.new(1_i64)
    value["local_id"] = JSON::Any.new(old_id)
    value.delete("source_id")
    case record
    when Tinrelay::TransmissionSpoolRecord
      value["relay_transmission_id"] = JSON::Any.new(record.transmission_id)
    when Tinrelay::RejectedTransmissionSpoolRecord
      value.delete("transmission_id")
      value["relay_transmission_id"] = JSON::Any.new(record.transmission_id)
    end
    current = File.join(
      state == "pending" ? spool.pending : spool.routed,
      record.kind, "#{record.source_id}.json"
    )
    old = File.join(spool.root, state, "#{old_id}.json")
    File.delete(current)
    Tinrelay::AtomicPrivateFile.write(old, JSON::Any.new(value).to_pretty_json + '\n')
    {old_id, old}
  end

  def self.json_snapshot(root : String) : Hash(String, String)
    pattern = Path.new(File.join(root, "**", "*.json")).to_posix
    Dir.glob(pattern).sort.to_h { |path| {path, File.read(path)} }
  end
end

describe Tinrelay::LocalStateMigration do
  it "moves pending and routed evidence to signed source identities and preserves recovery" do
    TinrelaySpec.with_server do |root, origin, _api|
      home = File.join(root, "home")
      paths = Tinrelay::LocalPaths.new("alpha", home)
      alpha = Tinrelay::Client.join(paths.keyring, origin, "alpha", paths.owner_key)
      beta = TinrelaySpec.admit_contact(root, origin, "beta", alpha)
      capture = TinrelaySpec::CaptureRemote.new(origin)
      Tinrelay::Client.new(beta.keyring, capture)
        .send("steward@alpha", "migration words", "caller")
      receiver = Tinrelay::Client.new(
        alpha.keyring, MigrationSequenceRemote.new(origin, capture.captured.first)
      )
      spool = Tinrelay::Spool.new(paths.spool)
      transmission_event = receiver.radio_wait(spool, hold_seconds: 0)
      transmission = spool.get(
        transmission_event.kind, transmission_event.source_id
      ).as(Tinrelay::TransmissionSpoolRecord)

      now = Time.utc.to_unix
      hail = Tinrelay::Hail.new(
        Tinrelay::Ids.uuid, "beta", 1, "alpha", now, now + 60, "signature"
      )
      certificate = Tinrelay::ShipRadioCertificate.new(
        "beta", 1, "signing", "encryption", now, 1, "owner-signature"
      )
      hail_record = spool.store_hail(
        hail, certificate, [Tinrelay::OwnerKeyLink.new(1, "owner")]
      )
      spool.routed(hail_record.kind, hail_record.source_id)

      transmission_old_id, transmission_old_path =
        TinrelayLocalStateMigrationSpec.downgrade(spool, "pending", transmission)
      hail_old_id, hail_old_path =
        TinrelayLocalStateMigrationSpec.downgrade(spool, "routed", hail_record)
      target = File.join(
        home, ".local", "share", "tinrelay-codex-bridge", "pending", "alpha.json"
      )
      task_id = "019a6d13-2f40-7b21-8c59-5a9d23f11e70"
      Tinrelay::AtomicPrivateFile.write(
        target,
        {
          local_id: transmission_old_id,
          task_id:  task_id,
          state:    "receipt_unknown",
        }.to_json + '\n'
      )

      valid_legacy_bytes = File.read(transmission_old_path)
      corrupt = JSON.parse(valid_legacy_bytes).as_h
      corrupt["signed_transmission"].as_h["signature"] = JSON::Any.new(
        Tinrelay::Crypto.b64(Tinrelay::Crypto.random(64))
      )
      File.write(transmission_old_path, JSON::Any.new(corrupt).to_pretty_json + '\n')
      expect_raises(
        Tinrelay::Error, "inbox signed transmission verification failed"
      ) { Tinrelay::LocalStateMigration.new(paths).run }
      File.exists?(transmission_old_path).should be_true
      JSON.parse(File.read(target))["local_id"].as_s.should eq(transmission_old_id)
      File.write(transmission_old_path, valid_legacy_bytes)

      expect_raises(
        Tinrelay::Invalid, "local inbox format requires `tinrelay migrate`"
      ) { Tinrelay::Spool.open_existing(paths.spool).list }

      Tinrelay::LocalStateMigration.new(paths).run

      File.exists?(transmission_old_path).should be_false
      File.exists?(hail_old_path).should be_false
      migrated = Tinrelay::Spool.open_existing(paths.spool)
      migrated.status("transmission", transmission.transmission_id).should eq({
        state: "pending", source_id: transmission.transmission_id,
        kind: "transmission",
      })
      migrated.status("hail", hail.hail_id).should eq({
        state: "routed", source_id: hail.hail_id, kind: "hail",
      })
      JSON.parse(File.read(target)).as_h.should eq({
        "kind"      => JSON::Any.new("transmission"),
        "source_id" => JSON::Any.new(transmission.transmission_id),
        "task_id"   => JSON::Any.new(task_id),
        "state"     => JSON::Any.new("receipt_unknown"),
      })
      before = TinrelayLocalStateMigrationSpec.json_snapshot(home)
      Tinrelay::LocalStateMigration.new(paths).run
      TinrelayLocalStateMigrationSpec.json_snapshot(home).should eq(before)
      hail_old_id.should_not eq(transmission_old_id)
    end
  end

  it "rejects an unmatched bridge binding before changing legacy evidence" do
    root = TinrelaySpec.temporary_root
    home = File.join(root, "home")
    paths = Tinrelay::LocalPaths.new("alpha", home)
    spool = Tinrelay::Spool.new(paths.spool)
    transmission_id = Tinrelay::Ids.uuid
    envelope = Tinrelay::SignedRelayEnvelope.new(
      transmission_id, "beta", 1, "alpha", 1,
      Time.utc.to_unix, Time.utc.to_unix + 60, "ciphertext"
    )
    rejection = spool.store_rejection(envelope, "unusable_envelope")
    _old_id, old_path = TinrelayLocalStateMigrationSpec.downgrade(
      spool, "pending", rejection
    )
    old_bytes = File.read(old_path)
    target = File.join(
      home, ".local", "share", "tinrelay-codex-bridge", "pending", "alpha.json"
    )
    Tinrelay::AtomicPrivateFile.write(
      target, {local_id: "tr_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
               task_id:  Tinrelay::Ids.uuid}.to_json + '\n'
    )

    expect_raises(
      Tinrelay::Invalid, "bridge pending target has no matching inbox record"
    ) { Tinrelay::LocalStateMigration.new(paths).run }
    File.read(old_path).should eq(old_bytes)
    Dir.glob(Path.new(File.join(paths.spool, "**", "*.json")).to_posix)
      .should eq([old_path])
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "refuses while either local consumer owns its ship lock" do
    root = TinrelaySpec.temporary_root
    home = File.join(root, "home")
    paths = Tinrelay::LocalPaths.new("alpha", home)
    Tinrelay::Spool.new(paths.spool)

    {"local-delivery.lock", "radio-wait.lock"}.each do |name|
      path = File.join(paths.spool, name)
      File.open(path, "a", perm: 0o600) do |lock|
        lock.flock_exclusive
        expect_raises(
          Tinrelay::Conflict, "local TinRelay delivery must stop before migration"
        ) { Tinrelay::LocalStateMigration.new(paths).run }
      end
    end
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
