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

module TinrelayCodexBridgeProcessSpec
  def self.with_harness(&)
    harness = Harness.new
    begin
      yield harness
    ensure
      harness.close
    end
  end
end
