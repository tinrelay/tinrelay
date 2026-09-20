require "json"
require "socket"
require "file_utils"
require "uuid"

require "../spec_helper"
require "../../src/tinrelay_codex_bridge/bridge"

{% if flag?(:win32) %}
  require "../support/windows_named_pipe_servers"
{% end %}

module TinrelayCodexBridgeProcessSpec
  REPO        = File.expand_path("../..", __DIR__)
  BUILD_ROOT  = File.join(Dir.tempdir, "tinrelay-bridge-spec-#{Process.pid}")
  BINARY_NAME = {% if flag?(:win32) %}
                  "tinrelay-codex-bridge.exe"
                {% elsif flag?(:darwin) || flag?(:linux) %}
                  "tinrelay-codex-bridge"
                {% else %}
                     {% raise "TinRelay specs do not support this platform" %}
                   {% end %}
  FIXTURE_NAME = {% if flag?(:win32) %}
                   "tinrelay-codex-bridge-fake.exe"
                 {% elsif flag?(:darwin) || flag?(:linux) %}
                   "tinrelay-codex-bridge-fake"
                 {% else %}
                     {% raise "TinRelay specs do not support this platform" %}
                   {% end %}
  BINARY         = File.join(BUILD_ROOT, BINARY_NAME)
  FIXTURE        = File.join(BUILD_ROOT, FIXTURE_NAME)
  BRIDGE_SOURCE  = File.join(REPO, "src", "tinrelay_codex_bridge_cli.cr")
  FIXTURE_SOURCE = File.join(
    REPO, "spec", "support", "tinrelay_codex_bridge_fake.cr"
  )
  TASK       = "11111111-2222-3333-4444-555555555555"
  OTHER_TASK = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

  @@binaries_ready = false

  def self.ensure_binaries
    binaries = {BRIDGE_SOURCE => BINARY, FIXTURE_SOURCE => FIXTURE}
    return if @@binaries_ready && binaries.values.all? { |path| File.file?(path) }
    Dir.mkdir_p(BUILD_ROOT)
    binaries.each do |source, target|
      result = Process.run(
        "crystal",
        ["build", source, "-o", target, "--release", "--warnings=all", "--error-on-warnings"],
        output: STDOUT,
        error: STDERR
      )
      raise "could not build #{File.basename(target)}" unless result.success?
    end
    @@binaries_ready = true
  end

  def self.event(number = 1, kind = "transmission", name : String? = "operator")
    {
      contract: "tinrelay-radio-wait-v1",
      local_id: "tr_#{number.to_s(16).rjust(32, '0')}",
      kind:     kind,
      name:     name,
      wrapper:  "TINRELAY LOCAL POINTER #{number}\nexact body-free wrapper",
    }
  end

  def self.eventually(within = 5.seconds, &)
    deadline = Time.instant + within
    until yield
      raise "condition did not become true" if Time.instant >= deadline
      sleep 20.milliseconds
    end
  end

  class ManagedProcess
    getter process : Process

    def initialize(@process)
      @status = nil.as(Process::Status?)
      @done = Channel(Process::Status).new(1)
      spawn do
        result = process.wait
        @status = result
        @done.send(result)
      end
    end

    def running?
      @status.nil? && Process.exists?(process.pid)
    end

    def wait(within = 5.seconds)
      return @status.not_nil! if @status
      select
      when result = @done.receive
        @status = result
        result
      when timeout(within)
        raise "process did not exit"
      end
    end

    def signal(signal : Signal)
      {% if flag?(:win32) %}
        process.terminate
      {% elsif flag?(:darwin) || flag?(:linux) %}
        process.signal(signal)
      {% else %}
        {% raise "TinRelay specs do not support this platform" %}
      {% end %}
    rescue RuntimeError
    end
  end

  class Harness
    @app_tools_path : String
    {% if flag?(:win32) %}
      @windows_server : TinrelaySpec::WindowsAppToolsServer?
    {% elsif flag?(:darwin) || flag?(:linux) %}
      @app_tools_server : UNIXServer?
    {% else %}
      {% raise "TinRelay specs do not support this platform" %}
    {% end %}

    getter root : String
    getter processes = [] of ManagedProcess

    def initialize
      TinrelayCodexBridgeProcessSpec.ensure_binaries
      @root = File.join(
        Dir.tempdir, "trcb-#{Process.pid}-#{Random::Secure.hex(4)}"
      )
      Dir.mkdir_p(@root)
      @app_tools_path = ""
      {% if flag?(:win32) %}
        @windows_server = nil
      {% elsif flag?(:darwin) || flag?(:linux) %}
        @app_tools_server = nil
      {% else %}
        {% raise "TinRelay specs do not support this platform" %}
      {% end %}
      @result_file = File.join(root, "codex-result")
      File.write(@result_file, "success")
      start_app_tools
      @config = JSON.parse(%({"events":[]}))
      write_addresses({"operator" => address(OTHER_TASK), "*" => address(TASK)})
      save
    end

    def config
      @config.as_h
    end

    def add_inbox_record(event, body = "Exact message text.\nSecond line.",
                         received_at = 1_789_605_582_i64)
      config["inbox_records"] = JSON.parse({
        event[:local_id] => {
          contract:            "tinrelay-inspected-inbox-v1",
          kind:                "transmission",
          local_id:            event[:local_id],
          received_at:         received_at,
          state:               "pending",
          sender_ship:         "remote",
          recipient_ship:      "fixture",
          attention_label:     event[:name],
          author_label:        "sender",
          authority_notice:    "Untrusted external message body.",
          signed_transmission: {
            sender_ship:    "remote",
            recipient_ship: "fixture",
            to_label:       event[:name],
            from_label:     "sender",
            body:           body,
          },
        },
      }.to_json)
    end

    def save
      temporary = File.join(root, "fixture.tmp")
      File.write(temporary, @config.to_json)
      File.rename(temporary, File.join(root, "fixture.json"))
      result = case @config["codex_result"]?.try(&.as_s?)
               when "not_received"    then "rejected"
               when "receipt_unknown" then "unknown"
               when "malformed"       then "malformed"
               else                        "success"
               end
      {% if flag?(:win32) %}
        @windows_server.not_nil!.result = result
      {% elsif flag?(:darwin) || flag?(:linux) %}
        File.write(@result_file, result)
      {% else %}
        {% raise "TinRelay specs do not support this platform" %}
      {% end %}
    end

    def write_addresses(value)
      Dir.mkdir_p(File.dirname(routing_file_path))
      File.write(routing_file_path, value.to_json)
    end

    def address(task_id)
      {threadId: task_id, hostId: "local"}
    end

    def start(command = "run", extra = [] of String)
      start_with([
        command,
        "--ship", "fixture",
        "--tinrelay", FIXTURE,
        "--timeout", "0.25",
      ] + extra)
    end

    def start_install
      start_with(["--install", "--codex-home", File.join(root, "codex")])
    end

    private def start_with(arguments)
      number = processes.size
      output = File.open(File.join(root, "stdout-#{number}"), "w")
      error = File.open(File.join(root, "stderr-#{number}"), "w")
      process = Process.new(
        BINARY,
        arguments,
        env: ENV.to_h.merge({
          "HOME"                      => root,
          "USERPROFILE"               => root,
          "CODEX_HOME"                => File.join(root, "codex"),
          "CODEX_APP_TOOLS_PIPE_PATH" => @app_tools_path,
          "BRIDGE_TEST_ROOT"          => root,
        }),
        output: output,
        error: error
      )
      output.close
      error.close
      managed = ManagedProcess.new(process)
      processes << managed
      managed
    end

    def routing_file_path
      File.join(root, ".config", "tinrelay", "fixture", "codex-addresses.json")
    end

    def pending_target_path
      File.join(root, ".local", "share", "tinrelay-codex-bridge", "pending", "fixture.json")
    end

    def child_calls(action : String? = nil)
      rows = rows_at("child_calls.jsonl")
      return rows unless action
      rows.select do |row|
        row["args"].as_a.first(2).map(&.as_s) == ["radio", action]
      end
    end

    def codex_calls(operation : String? = nil)
      rows = {% if flag?(:win32) %}
               @windows_server.not_nil!.requests
             {% elsif flag?(:darwin) || flag?(:linux) %}
               rows_at("codex_calls.jsonl")
             {% else %}
               {% raise "TinRelay specs do not support this platform" %}
             {% end %}
      return rows unless operation
      rows.select { |row| row["operation"].as_s == operation }
    end

    def output(number = 0)
      path = File.join(root, "stdout-#{number}")
      File.exists?(path) ? File.read(path) : ""
    end

    def assert_blocked(process, reason, code = 1)
      process.wait(8.seconds).exit_code.should eq(code)
      output(processes.index!(process)).should contain(%("reason":"#{reason}"))
    end

    def close
      processes.each do |process|
        next unless process.running?
        process.signal(Signal::TERM)
        begin
          process.wait(4.seconds)
        rescue
          {% if flag?(:win32) %}
            process.process.terminate
          {% elsif flag?(:darwin) || flag?(:linux) %}
            process.signal(Signal::KILL)
          {% else %}
            {% raise "TinRelay specs do not support this platform" %}
          {% end %}
          process.wait
        end
      end
      {% if flag?(:win32) %}
        @windows_server.try(&.close)
      {% elsif flag?(:darwin) || flag?(:linux) %}
        @app_tools_server.try(&.close)
      {% else %}
        {% raise "TinRelay specs do not support this platform" %}
      {% end %}
      FileUtils.rm_r(root) if Dir.exists?(root)
    end

    private def rows_at(name)
      path = File.join(root, name)
      return [] of JSON::Any unless File.exists?(path)
      File.read_lines(path).map { |line| JSON.parse(line) }
    end

    private def start_app_tools
      {% if flag?(:win32) %}
        name = "tinrelay-codex-bridge-#{Process.pid}-#{Random::Secure.hex(4)}"
        @app_tools_path = "\\\\.\\pipe\\#{name}"
        @windows_server = TinrelaySpec::WindowsAppToolsServer.new(name)
      {% elsif flag?(:darwin) || flag?(:linux) %}
        @app_tools_path = File.join(root, "app-tools.sock")
        @app_tools_server = UNIXServer.new(@app_tools_path)
        spawn { serve_app_tools }
      {% else %}
        {% raise "TinRelay specs do not support this platform" %}
      {% end %}
    end

    {% if flag?(:darwin) || flag?(:linux) %}
      private def serve_app_tools
        loop do
          client = @app_tools_server.not_nil!.accept
          handle_app_tools(client)
        end
      rescue IO::Error
      end

      private def handle_app_tools(client)
        request = read_frame(client)
        if request["method"].as_s == "tools/list"
          record_codex_call({operation: "discover", candidates: [@app_tools_path]})
          write_frame(client, {
            id:      1,
            jsonrpc: "2.0",
            result:  {
              tools: [{name: "send_message_to_thread", namespace: "codex_app"}],
            },
          })
          return
        end

        params = request["params"]
        arguments = params["arguments"]
        target = arguments["threadId"].as_s
        record_codex_call({
          operation:    "send",
          candidates:   [@app_tools_path],
          sourceTaskId: params["threadId"].as_s,
          targetTaskId: target,
          prompt:       arguments["prompt"].as_s,
        })

        case File.read(@result_file)
        when "unknown"
          return
        when "malformed"
          write_raw_frame(client, "not json")
        when "rejected"
          write_frame(client, {
            id:      1,
            jsonrpc: "2.0",
            error:   {message: "task_not_received"},
          })
        else
          write_frame(client, {
            id:      1,
            jsonrpc: "2.0",
            result:  {
              success:      true,
              contentItems: [{type: "inputText", text: {threadId: target}.to_json}],
            },
          })
        end
      ensure
        client.close
      end

      private def read_frame(io)
        header = Bytes.new(4)
        io.read_fully(header)
        size = IO::ByteFormat::LittleEndian.decode(UInt32, header)
        body = Bytes.new(size.to_i)
        io.read_fully(body)
        JSON.parse(String.new(body))
      end

      private def write_frame(io, value)
        write_raw_frame(io, value.to_json)
      end

      private def write_raw_frame(io, body : String)
        header = Bytes.new(4)
        IO::ByteFormat::LittleEndian.encode(body.bytesize.to_u32, header)
        io.write(header)
        io << body
        io.flush
      end

      private def record_codex_call(value)
        File.open(File.join(root, "codex_calls.jsonl"), "a") do |file|
          file.puts(value.to_json)
        end
      end
    {% end %}
  end
end

include TinrelayCodexBridgeProcessSpec

Spec.after_suite do
  root = TinrelayCodexBridgeProcessSpec::BUILD_ROOT
  FileUtils.rm_r(root) if Dir.exists?(root)
end

private def with_bridge_harness(&)
  harness = TinrelayCodexBridgeProcessSpec::Harness.new
  begin
    yield harness
  ensure
    harness.close
  end
end

private def eventually(within = 5.seconds, &)
  TinrelayCodexBridgeProcessSpec.eventually(within) { yield }
end

describe "tinrelay-codex-bridge process contract" do
  it "rejects an invalid timeout" do
    with_bridge_harness do |h|
      process = h.start(extra: ["--timeout", "never"])

      h.assert_blocked(process, "invalid_timeout")
    end
  end

  it "installs the platform bridge through one top-level command" do
    with_bridge_harness do |h|
      process = h.start_install

      process.wait(10.seconds).exit_code.should eq(0)
      {% if flag?(:darwin) %}
        h.output.should eq("codex_restart_required\n")
        relay = File.join(h.root, "codex", "codex-bridge", "relay.mjs")
        File.read(relay).should contain("send_message_to_thread")
      {% else %}
        h.output.should eq("ready\n")
      {% end %}
    end
  end

  it "checks discovery and the address book without sending a message" do
    with_bridge_harness do |h|
      process = h.start("check")

      process.wait.exit_code.should eq(0)
      h.output.should contain(%("state":"ready"))
      h.codex_calls("discover").size.should eq(1)
      h.codex_calls("send").should be_empty
    end
  end

  it "accepts the now-redundant deref option from existing service definitions" do
    with_bridge_harness do |h|
      process = h.start("check", extra: ["--deref"])

      process.wait.exit_code.should eq(0)
      h.output.should contain(%("state":"ready"))
    end
  end

  it "can deliver exact and fallback events as self-attributed body-free pointers" do
    with_bridge_harness do |h|
      events = [
        TinrelayCodexBridgeProcessSpec.event,
        TinrelayCodexBridgeProcessSpec.event(2, "hail", nil),
        TinrelayCodexBridgeProcessSpec.event(3, "rejected_transmission", nil),
      ]
      h.config["events"] = JSON.parse(events.to_json)
      h.save

      h.start(extra: ["--pointer"])
      eventually { h.child_calls("wait").size == 4 }

      sends = h.codex_calls("send")
      sends.size.should eq(3)
      sends.each_with_index do |request, index|
        expected = index == 0 ? OTHER_TASK : TASK
        request["sourceTaskId"].as_s.should eq(expected)
        request["targetTaskId"].as_s.should eq(expected)
        request["prompt"].as_s.should eq(events[index][:wrapper])
      end
      h.child_calls("routed").size.should eq(3)
      File.exists?(h.pending_target_path).should be_false
    end
  end

  it "dereferences transmissions into full message deliveries by default" do
    with_bridge_harness do |h|
      event = TinrelayCodexBridgeProcessSpec.event
      h.config["events"] = JSON.parse([event].to_json)
      h.add_inbox_record(event)
      h.save

      h.start
      eventually { h.child_calls("wait").size == 2 }

      prompt = h.codex_calls("send").first["prompt"].as_s
      lines = prompt.lines
      lines.first.should eq("TINRELAY MESSAGE DELIVERY")
      delivery = JSON.parse(lines[1])
      delivery["contract"].as_s.should eq("tinrelay-message-delivery-v1")
      delivery.as_h.keys.sort.should eq([
        "attention_label",
        "author_label",
        "body",
        "contract",
        "kind",
        "local_id",
        "local_ship",
        "received_at",
        "sender_ship",
      ])
      delivery["local_id"].as_s.should eq(event[:local_id])
      delivery["sender_ship"].as_s.should eq("remote")
      delivery["attention_label"].as_s.should eq("operator")
      delivery["author_label"].as_s.should eq("sender")
      delivery["body"].as_s.should eq("Exact message text.\nSecond line.")
      delivery["received_at"].as_i64.should eq(1_789_605_582_i64)
      h.child_calls.count do |call|
        call["args"].as_a.first(2).map(&.as_s) == ["inbox", "show"]
      end.should eq(1)
    end
  end

  it "rejects deliveries without a positive integer receive time" do
    [
      {"missing", nil},
      {"zero", JSON::Any.new(0_i64)},
      {"string", JSON::Any.new("1789605582")},
    ].each do |label, received_at|
      with_bridge_harness do |h|
        event = TinrelayCodexBridgeProcessSpec.event
        h.config["events"] = JSON.parse([event].to_json)
        h.add_inbox_record(event)
        record = h.config["inbox_records"][event[:local_id]].as_h
        if received_at
          record["received_at"] = received_at
        else
          record.delete("received_at")
        end
        h.save

        process = h.start
        h.assert_blocked(process, "invalid_inbox_output")
        h.codex_calls("send").should be_empty, label
        h.child_calls("routed").should be_empty, label
      end
    end
  end

  it "never falls through from an invalid exact address to the fallback" do
    with_bridge_harness do |h|
      event = TinrelayCodexBridgeProcessSpec.event
      h.config["events"] = JSON.parse([event].to_json)
      h.save
      h.write_addresses({
        "operator" => h.address("not-a-task"),
        "*"        => h.address(TASK),
      })

      process = h.start
      h.assert_blocked(process, "invalid_address")
      h.codex_calls("send").should be_empty
      h.child_calls("routed").should be_empty
    end
  end

  it "retries a definite refusal only against the frozen target" do
    with_bridge_harness do |h|
      event = TinrelayCodexBridgeProcessSpec.event
      h.config["events"] = JSON.parse([event].to_json)
      h.config["codex_result"] = JSON::Any.new("not_received")
      h.add_inbox_record(event)
      h.save

      process = h.start
      eventually { h.codex_calls("send").size >= 2 }
      h.write_addresses({"operator" => h.address(TASK), "*" => h.address(TASK)})
      eventually { h.codex_calls("send").size >= 3 }

      h.codex_calls("send").each do |request|
        request["targetTaskId"].as_s.should eq(OTHER_TASK)
      end
      binding = JSON.parse(File.read(h.pending_target_path))
      binding["task_id"].as_s.should eq(OTHER_TASK)
      binding["state"].as_s.should eq("ready")
      process.running?.should be_true
    end
  end

  it "pins an unknown receipt and never resubmits it after restart" do
    with_bridge_harness do |h|
      event = TinrelayCodexBridgeProcessSpec.event
      h.config["events"] = JSON.parse([event].to_json)
      h.config["codex_result"] = JSON::Any.new("receipt_unknown")
      h.add_inbox_record(event)
      h.save

      first = h.start
      h.assert_blocked(first, "delivery_receipt_unknown")
      h.codex_calls("send").size.should eq(1)
      binding = JSON.parse(File.read(h.pending_target_path))
      binding["state"].as_s.should eq("receipt_unknown")

      h.config["codex_result"] = JSON::Any.new("success")
      h.save
      second = h.start
      h.assert_blocked(second, "delivery_receipt_unknown")
      h.codex_calls("send").size.should eq(1)
      h.child_calls("routed").should be_empty
    end
  end

  it "finishes a definitely delivered event after a routed-mark restart" do
    with_bridge_harness do |h|
      event = TinrelayCodexBridgeProcessSpec.event
      h.config["events"] = JSON.parse([event].to_json)
      h.config["routed_failure"] = JSON::Any.new(true)
      h.add_inbox_record(event)
      h.save

      first = h.start
      h.assert_blocked(first, "tinrelay_routed_failed")
      h.codex_calls("send").size.should eq(1)
      JSON.parse(File.read(h.pending_target_path))["state"].as_s.should eq("delivered")

      h.config["routed_failure"] = JSON::Any.new(false)
      h.save
      second = h.start
      eventually { h.child_calls("wait").size == 3 }
      h.codex_calls("send").size.should eq(1)
      h.child_calls("routed").size.should eq(2)
      File.exists?(h.pending_target_path).should be_false
      second.running?.should be_true
    end
  end

  it "keeps one bridge owner and stops its waiting child when the bridge terminates" do
    with_bridge_harness do |h|
      first = h.start
      eventually { h.child_calls("wait").size == 1 }
      child_pid = h.child_calls("wait").first["pid"].as_i

      second = h.start
      second.wait.exit_code.should eq(0)
      h.output(1).should contain(%("reason":"bridge_already_running"))

      first.signal(Signal::TERM)
      status = first.wait(3.seconds)
      {% if flag?(:win32) %}
        status.exit_code.should eq(1)
      {% elsif flag?(:darwin) || flag?(:linux) %}
        status.exit_code.should eq(0)
      {% else %}
        {% raise "TinRelay specs do not support this platform" %}
      {% end %}
      eventually { !Process.exists?(child_pid) }
    end
  end

  it "terminates and reaps a child recorded after stop" do
    TinrelayCodexBridgeProcessSpec.ensure_binaries
    control = TinrelayCodexBridge::Control.new
    control.stop
    process = Process.new(
      TinrelayCodexBridgeProcessSpec::FIXTURE,
      env: {"TINRELAY_CODEX_BRIDGE_PIPE_HOLDER" => "1"}
    )

    expect_raises(TinrelayCodexBridge::Stopped) do
      control.child = process
    end
    Process.exists?(process.pid).should be_false
  end

  {% if flag?(:win32) %}
    it "creates reusable private ACLs for both bridge ownership locks" do
      with_bridge_harness do |h|
        process = h.start
        eventually { h.child_calls("wait").size == 1 }

        locks = [
          File.join(
            h.root, ".local", "share", "tinrelay-codex-bridge", "locks", "fixture.lock"
          ),
          File.join(
            h.root, ".local", "share", "tinrelay", "fixture", "inbox",
            "local-delivery.lock"
          ),
        ]
        locks.each do |path|
          File.exists?(path).should be_true
          Tinrelay::PrivateStorage.private?(path).should be_true
          Tinrelay::PrivateStorage.private?(File.dirname(path)).should be_true
        end
        process.running?.should be_true
      end
    end
  {% end %}
end
