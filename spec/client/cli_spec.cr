require "json"

require "../spec_helper"

{% if flag?(:win32) %}
  require "../support/windows_named_pipe_servers"
{% end %}

module TinrelayCliSpec
  REPO       = File.expand_path("../..", __DIR__)
  BUILD_ROOT = File.join(Dir.tempdir, "tinrelay-cli-send-spec-#{Process.pid}")
  BINARY     = File.join(BUILD_ROOT, "tinrelay")
  SOURCE     = File.join(REPO, "src", "tinrelay_cli.cr")
  @@binary_ready = false

  def self.ensure_binary : Nil
    return if @@binary_ready && File.file?(BINARY)
    Dir.mkdir_p(BUILD_ROOT)
    build = Process.run(
      "crystal",
      ["build", SOURCE, "-o", BINARY, "--warnings=all", "--error-on-warnings"],
      output: STDOUT,
      error: STDERR
    )
    raise "could not build tinrelay CLI process fixture" unless build.success?
    @@binary_ready = true
  end

  def self.run(args : Array(String), body : String,
               home : String) : Tuple(Process::Status, String, String)
    ensure_binary
    output = IO::Memory.new
    error = IO::Memory.new
    process = Process.new(
      BINARY,
      args,
      env: {"HOME" => home},
      input: Process::Redirect::Pipe,
      output: output,
      error: error
    )
    process.input.print(body)
    process.input.close
    {process.wait, output.to_s, error.to_s}
  end

  {% if flag?(:win32) %}
    def self.run_without_home(args : Array(String), body : String, home : String,
                              cwd : String) : Tuple(Process::Status, String, String)
      ensure_binary
      output = IO::Memory.new
      error = IO::Memory.new
      environment = {"HOME" => nil, "USERPROFILE" => home}.as(Hash(String, String?))
      process = Process.new(
        BINARY,
        args,
        env: environment,
        chdir: cwd,
        input: Process::Redirect::Pipe,
        output: output,
        error: error
      )
      process.input.print(body)
      process.input.close
      {process.wait, output.to_s, error.to_s}
    end
  {% end %}

  def self.run_without_eof(args : Array(String), home : String) : Tuple(Process::Status, String)
    ensure_binary
    error = IO::Memory.new
    process = Process.new(
      BINARY,
      args,
      env: {"HOME" => home},
      input: Process::Redirect::Pipe,
      output: Process::Redirect::Close,
      error: error
    )
    status = Channel(Process::Status).new
    spawn { status.send(process.wait) }
    result = select
    when value = status.receive
      value
    when timeout(2.seconds)
      process.terminate
      process.input.close
      status.receive
      raise "CLI consumed or waited for transmission stdin before rejecting argv"
    end
    process.input.close
    {result, error.to_s}
  end
end

Spec.after_suite do
  root = TinrelayCliSpec::BUILD_ROOT
  FileUtils.rm_r(root) if Dir.exists?(root)
end

describe "tinrelay send CLI input" do
  it "pipes an implicit stdin body through the ordinary self-transmission path" do
    TinrelaySpec.with_server do |root, origin, _api|
      home = File.join(root, "home")
      paths = Tinrelay::LocalPaths.new("alpha", home)
      client = Tinrelay::Client.join(
        paths.keyring, origin, "alpha", paths.owner_key
      )

      status, output, error = TinrelayCliSpec.run(
        ["send", "@alpha", "--ship", "alpha"],
        "body from process stdin\n",
        home
      )
      status.success?.should be_true
      error.should be_empty
      sent = JSON.parse(output)
      sent["state"].as_s.should eq("accepted")
      sent["transmission_id"].as_s.should match(Tinrelay::Outbox::UUID)
      sent.as_h.keys.sort.should eq(%w(
        recipient_ship sender_ship state transmission_id
      ))

      event = client.radio_wait(Tinrelay::Spool.new(paths.spool), hold_seconds: 0)
      record = Tinrelay::Spool.new(paths.spool).get(event.kind, event.source_id)
        .as(Tinrelay::TransmissionSpoolRecord)
      record.signed_transmission.body.should eq("body from process stdin\n")
    end
  end

  {% if flag?(:win32) %}
    it "uses the Windows profile home when HOME is absent and cwd is elsewhere" do
      TinrelaySpec.with_server do |root, origin, _api|
        home = File.join(root, "home")
        cwd = File.join(root, "project")
        Dir.mkdir_p(cwd)
        paths = Tinrelay::LocalPaths.new("alpha", home)
        client = Tinrelay::Client.join(paths.keyring, origin, "alpha", paths.owner_key)

        status, output, error = TinrelayCliSpec.run_without_home(
          ["send", "@alpha", "--ship", "alpha"],
          "body from non-home cwd\n",
          home,
          cwd
        )
        status.success?.should be_true
        error.should be_empty
        sent = JSON.parse(output)
        sent["state"].as_s.should eq("accepted")
        sent["transmission_id"].as_s.should match(Tinrelay::Outbox::UUID)

        event = client.radio_wait(Tinrelay::Spool.new(paths.spool), hold_seconds: 0)
        record = Tinrelay::Spool.new(paths.spool).get(event.kind, event.source_id)
          .as(Tinrelay::TransmissionSpoolRecord)
        record.signed_transmission.body.should eq("body from non-home cwd\n")
      end
    end

    it "emits the outgoing observer event from the built CLI with HOME absent" do
      TinrelaySpec.with_server do |root, origin, _api|
        home = File.join(root, "home")
        cwd = File.join(root, "project")
        Dir.mkdir_p(cwd)
        paths = Tinrelay::LocalPaths.new("alpha", home)
        client = Tinrelay::Client.join(paths.keyring, origin, "alpha", paths.owner_key)
        listener = TinrelaySpec::WindowsLineServer.new(
          "tinrelay-cli-observer-spec-#{Process.pid}-#{Random::Secure.hex(4)}"
        )
        begin
          Tinrelay::AtomicPrivateFile.write(
            paths.outgoing_observer,
            Tinrelay::OutgoingObserver::Config.new(listener.path).to_json
          )

          status, output, error = TinrelayCliSpec.run_without_home(
            ["send", "@alpha", "--ship", "alpha"],
            "body observed from built CLI\n",
            home,
            cwd
          )
          status.success?.should be_true
          error.should be_empty
          sent = JSON.parse(output)
          sent["state"].as_s.should eq("accepted")
          sent["transmission_id"].as_s.should match(Tinrelay::Outbox::UUID)

          event = JSON.parse(listener.receive)
          event["contract"].as_s.should eq(Tinrelay::OutgoingObserver::CONTRACT)
          event["transmission_id"].as_s.should eq(sent["transmission_id"].as_s)
          event.as_h.has_key?("local_id").should be_false
          event["sender_ship"].as_s.should eq("alpha")
          event["recipient_ship"].as_s.should eq("alpha")
          event["body"].as_s.should eq("body observed from built CLI\n")

          radio_event = client.radio_wait(
            Tinrelay::Spool.new(paths.spool), hold_seconds: 0
          )
          radio_event.kind.should eq("transmission")
        ensure
          listener.close
        end
      end
    end
  {% end %}

  it "rejects extra arguments without waiting for or consuming body stdin" do
    root = TinrelaySpec.temporary_root
    status, error = TinrelayCliSpec.run_without_eof(
      ["send", "@alpha", "extra", "--ship", "alpha"], root
    )

    status.exit_code.should eq(2)
    JSON.parse(error)["message"].as_s.should eq("unexpected arguments: extra")
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "rejects the legacy passphrase flag on ordinary commands before reading stdin" do
    root = TinrelaySpec.temporary_root
    status, error = TinrelayCliSpec.run_without_eof(
      ["send", "@alpha", "--passphrase-file", "-", "--ship", "alpha"],
      root
    )

    status.exit_code.should eq(2)
    JSON.parse(error)["message"].as_s.should eq(
      "unexpected arguments: --passphrase-file -"
    )
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "resolves the sender keyring before reading the transmission body" do
    root = TinrelaySpec.temporary_root
    status, error = TinrelayCliSpec.run_without_eof(
      ["send", "@alpha", "--ship", "alpha"], root
    )

    status.exit_code.should eq(2)
    JSON.parse(error)["message"].as_s.should contain("keyring not found")
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end

describe "tinrelay outbox CLI" do
  it "lists the shared retained-envelope fact" do
    root = TinrelaySpec.temporary_root
    home = File.join(root, "home")
    paths = Tinrelay::LocalPaths.new("alpha", home)
    now = Time.utc.to_unix
    envelope = Tinrelay::SignedRelayEnvelope.new(
      Tinrelay::Ids.uuid, "alpha", 1, "beta", 1,
      now, now + 3600, Tinrelay::Crypto.b64(Tinrelay::Crypto.random(64))
    )
    Tinrelay::Outbox.new(paths.outbox).store(envelope)

    status, output, error = TinrelayCliSpec.run(
      ["--ship", "alpha", "outbox", "list"], "", home
    )
    status.success?.should be_true
    error.should be_empty
    result = JSON.parse(output)
    result["transmission_id"].as_s.should eq(envelope.transmission_id)
    result["state"].as_s.should eq("retained")
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end

describe "tinrelay sent and withdrawal CLI" do
  it "uses the transmission id for append-only sent evidence and blind withdrawal" do
    TinrelaySpec.with_server do |root, origin, _api|
      home = File.join(root, "home")
      paths = Tinrelay::LocalPaths.new("alpha", home)
      client = Tinrelay::Client.join(
        paths.keyring, origin, "alpha", paths.owner_key
      )

      send_status, send_output, send_error = TinrelayCliSpec.run(
        ["--ship", "alpha", "send", "notes@alpha", "--as", "rowan"],
        "keep these exact words\n",
        home
      )
      send_status.success?.should be_true
      send_error.should be_empty
      sent = JSON.parse(send_output)
      transmission_id = sent["transmission_id"].as_s
      transmission_id.should match(Tinrelay::Outbox::UUID)
      sent["state"].as_s.should eq("accepted")

      outgoing = Tinrelay::OutgoingStore.new(paths.outgoing, "alpha")
      before = File.read(outgoing.sent_path(transmission_id))

      list_status, list_output, list_error = TinrelayCliSpec.run(
        ["--ship", "alpha", "sent", "list"], "", home
      )
      list_status.success?.should be_true
      list_error.should be_empty
      listed = JSON.parse(list_output)
      listed["transmission_id"].as_s.should eq(transmission_id)
      listed["destination"].as_s.should eq("notes@alpha")
      listed["withdrawal_requested"].as_bool.should be_false
      list_output.should_not contain("keep these exact words")

      show_status, show_output, show_error = TinrelayCliSpec.run(
        ["--ship", "alpha", "sent", "show", transmission_id], "", home
      )
      show_status.success?.should be_true
      show_error.should be_empty
      shown = JSON.parse(show_output)
      shown["body"].as_s.should eq("keep these exact words\n")
      shown["author_label"].as_s.should eq("rowan")
      shown["transmission_id"].as_s.should eq(transmission_id)

      withdraw_status, withdraw_output, withdraw_error = TinrelayCliSpec.run(
        ["--ship", "alpha", "withdraw", transmission_id], "", home
      )
      withdraw_status.success?.should be_true
      withdraw_error.should be_empty
      JSON.parse(withdraw_output).should eq(JSON.parse(
        {state: "withdrawal_requested", transmission_id: transmission_id}.to_json
      ))
      File.read(outgoing.sent_path(transmission_id)).should eq(before)
      outgoing.withdrawal_requested?(transmission_id).should be_true
      client.radio_poll(Tinrelay::Spool.new(paths.spool)).should be_nil
    end
  end
end

describe "tinrelay nested contact commands" do
  it "allows, closes, and unblocks the authenticated peer from a local hail ID" do
    TinrelaySpec.with_server do |root, origin, api|
      home = File.join(root, "home")
      paths = Tinrelay::LocalPaths.new("beta", home)
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = Tinrelay::Client.join(
        paths.keyring, origin, "beta", paths.owner_key
      )
      alpha.hail("beta")
      event = beta.radio_wait(Tinrelay::Spool.new(paths.spool), hold_seconds: 0)

      status, output, error = TinrelayCliSpec.run(
        ["--ship", "beta", "contact", "allow", event.source_id], "", home
      )
      status.success?.should be_true
      error.should be_empty
      result = JSON.parse(output)
      result["peer_ship"].as_s.should eq("alpha")
      result["hail_id"].as_s.should eq(event.source_id)
      api.database.db.query_one(
        "SELECT state FROM relationships WHERE ship_a = 'alpha' AND ship_b = 'beta'",
        as: String
      ).should eq("active")

      close_status, close_output, close_error = TinrelayCliSpec.run(
        ["--ship", "beta", "contact", "close", "alpha"], "", home
      )
      close_status.success?.should be_true
      close_error.should be_empty
      JSON.parse(close_output)["state"].as_s.should eq("closed")

      unblock_status, unblock_output, unblock_error = TinrelayCliSpec.run(
        ["--ship", "beta", "contact", "unblock", "alpha"], "", home
      )
      unblock_status.success?.should be_true
      unblock_error.should be_empty
      JSON.parse(unblock_output)["state"].as_s.should eq("unblocked")
    end
  end
end

describe "tinrelay nested owner commands" do
  it "rotates the selected ship owner" do
    TinrelaySpec.with_server do |root, origin, _api|
      home = File.join(root, "home")
      paths = Tinrelay::LocalPaths.new("alpha", home)
      Tinrelay::Client.join(
        paths.keyring, origin, "alpha", paths.owner_key
      )

      status, output, error = TinrelayCliSpec.run(
        ["--ship", "alpha", "owner", "rotate"], "", home
      )
      status.success?.should be_true
      error.should be_empty
      result = JSON.parse(output)
      result["state"].as_s.should eq("rotated")
      result["owner_generation"].as_i.should eq(2)
    end
  end
end

describe "tinrelay local key migration" do
  it "remains as a harmless compatibility command" do
    root = TinrelaySpec.temporary_root
    home = File.join(root, "home")

    status, output, error = TinrelayCliSpec.run(
      ["--ship", "alpha", "migrate"], "", home
    )

    status.success?.should be_true
    error.should be_empty
    result = JSON.parse(output)
    result["state"].as_s.should eq("current")
    result["ship"].as_s.should eq("alpha")
    Dir.exists?(home).should be_false
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "requires and performs the temporary incoming source-identity migration" do
    root = TinrelaySpec.temporary_root
    home = File.join(root, "home")
    paths = Tinrelay::LocalPaths.new("alpha", home)
    spool = Tinrelay::Spool.new(paths.spool)
    transmission_id = "11111111-1111-4111-8111-111111111111"
    reason = "unusable_envelope"
    evidence_id = Tinrelay::RejectionEvidence.id(transmission_id, reason)
    legacy_path = File.join(spool.pending, "#{evidence_id}.json")
    Tinrelay::AtomicPrivateFile.write(
      legacy_path,
      {
        format: 1, kind: "rejected_transmission", local_id: evidence_id,
        received_at: 10_i64, relay_transmission_id: transmission_id,
        rejection_reason: reason,
      }.to_json + '\n'
    )

    list_status, _list_output, list_error = TinrelayCliSpec.run(
      ["--ship", "alpha", "inbox", "list"], "", home
    )
    list_status.success?.should be_false
    JSON.parse(list_error)["message"].as_s.should eq(
      "local inbox format requires `tinrelay migrate`"
    )

    status, output, error = TinrelayCliSpec.run(
      ["--ship", "alpha", "migrate"], "", home
    )
    status.success?.should be_true
    error.should be_empty
    JSON.parse(output)["state"].as_s.should eq("current")
    File.exists?(legacy_path).should be_false
    migrated = Tinrelay::Spool.open_existing(paths.spool)
      .get("rejected_transmission", evidence_id)
      .as(Tinrelay::RejectedTransmissionSpoolRecord)
    migrated.transmission_id.should eq(transmission_id)
    migrated.rejection_reason.should eq(reason)
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end

describe "tinrelay global ship selector" do
  it "accepts the selector before or after a nested command" do
    root = TinrelaySpec.temporary_root
    [
      ["--ship", "alpha", "inbox", "list"],
      ["inbox", "list", "--ship", "alpha"],
    ].each do |args|
      status, output, error = TinrelayCliSpec.run(args, "", root)
      status.success?.should be_true
      output.should be_empty
      error.should be_empty
    end
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "rejects a missing or duplicate selector value" do
    root = TinrelaySpec.temporary_root
    missing, _, missing_error = TinrelayCliSpec.run(["--ship"], "", root)
    duplicate, _, duplicate_error = TinrelayCliSpec.run(
      ["--ship", "alpha", "inbox", "list", "--ship", "beta"], "", root
    )

    missing.exit_code.should eq(2)
    JSON.parse(missing_error)["message"].as_s.should eq("--ship requires a value")
    duplicate.exit_code.should eq(2)
    JSON.parse(duplicate_error)["message"].as_s.should eq("--ship may be provided only once")
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
