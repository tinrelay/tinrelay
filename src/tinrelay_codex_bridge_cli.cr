require "./tinrelay_codex_bridge/bridge"

module TinrelayCodexBridge
  HELP = <<-TEXT
    tinrelay-codex-bridge --install
    tinrelay-codex-bridge run --ship SHIP
    tinrelay-codex-bridge check --ship SHIP
    tinrelay-codex-bridge help
    tinrelay-codex-bridge version

    Optional: --tinrelay PATH, --codex-home PATH, --routing-file ABSOLUTE_PATH,
              --timeout SECONDS (default: 60)
    Transmission bodies are delivered by default.
    run stays in the foreground. check never submits a model turn.
    A second running instance and signals exit 0. check failures exit 2.
    Other blocked or unexpected run failures exit 1. Quiet listening spends no model turns.
    TEXT

  def self.main(argv : Array(String)) : Int32
    command = argv.shift? || "help"
    case command
    when "help", "--help", "-h"
      puts HELP
      return 0
    when "version", "--version"
      puts "tinrelay-codex-bridge #{VERSION}"
      return 0
    when "--install"
      codex_home = ENV["CODEX_HOME"]? || Path.home.join(".codex").to_s
      parser = OptionParser.new do |options|
        options.on("--codex-home PATH", "Codex home") { |value| codex_home = value }
        options.invalid_option { raise Blocked.new("invalid_option") }
        options.missing_option { raise Blocked.new("missing_option_value") }
      end
      parser.parse(argv)
      raise Blocked.new("unexpected_arguments") unless argv.empty?
      begin
        puts CodexBridge.install(codex_home)
      rescue ex : CodexBridge::InstallError
        raise Blocked.new(ex.reason)
      end
      return 0
    end
    raise Blocked.new("unknown_command") unless {"run", "check"}.includes?(command)
    ship = ""
    executable = "tinrelay"
    routing_file = nil.as(String?)
    codex_home = ENV["CODEX_HOME"]? || Path.home.join(".codex").to_s
    timeout = CodexBridge::Client::DEFAULT_TIMEOUT
    deref = true
    parser = OptionParser.new do |options|
      options.on("--ship SHIP", "Local ship") { |value| ship = value }
      options.on("--tinrelay PATH", "TinRelay executable") { |value| executable = value }
      options.on("--codex-home PATH", "Codex home") { |value| codex_home = value }
      options.on("--routing-file ABSOLUTE_PATH", "Ship-local Codex address book") do |value|
        routing_file = value
      end
      options.on("--timeout SECONDS", "Maximum time for delivery work") do |value|
        seconds = value.to_f64?
        unless seconds && seconds.finite? && seconds >= 0
          raise Blocked.new("invalid_timeout")
        end
        timeout = seconds.seconds
      end
      options.on("--deref", "Deliver transmission bodies instead of local pointers") do
        deref = true
      end
      options.on("--pointer", "Deliver local pointers instead of transmission bodies") do
        deref = false
      end
      options.invalid_option { raise Blocked.new("invalid_option") }
      options.missing_option { raise Blocked.new("missing_option_value") }
    end
    parser.parse(argv)
    raise Blocked.new("unexpected_arguments") unless argv.empty?
    config = Config.new(
      ship,
      executable,
      codex_home,
      routing_file: routing_file,
      timeout: timeout,
      deref: deref
    )
    control = Control.new
    Process.on_terminate { control.stop }
    runner = Runner.new(config, control)
    command == "run" ? runner.run : runner.check
    0
  rescue Stopped
    Reporter.new.emit("stopped", "signal")
    0
  rescue ex : AlreadyRunning
    Reporter.new.emit("blocked", ex.message)
    0
  rescue ex : Blocked
    Reporter.new.emit("blocked", ex.message)
    command == "run" ? 1 : 2
  rescue Exception
    Reporter.new(STDERR).emit("failed", "unexpected_bridge_failure")
    1
  end
end

exit TinrelayCodexBridge.main(ARGV.dup)
