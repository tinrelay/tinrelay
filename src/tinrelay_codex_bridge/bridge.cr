require "json"
require "option_parser"
require "codex_bridge"
require "../tinrelay/ids"
require "../tinrelay/local_paths"
require "../tinrelay/version"
require "../tinrelay/bounded_io"
require "../tinrelay/platform/private_storage"
require "./child_lifetime"

module TinrelayCodexBridge
  VERSION = Tinrelay::VERSION

  class Blocked < Exception; end

  class AlreadyRunning < Blocked; end

  class DeliveryUnavailable < Blocked; end

  class Stopped < Exception; end

  class Control
    getter stopped = false
    getter child : Process? = nil

    def initialize(@child_lifetime = ChildLifetime.new)
    end

    def child=(process : Process?) : Process?
      @child = process
      return unless process
      if stopped
        terminate_and_reap(process)
        @child = nil if @child == process
        raise Stopped.new
      end
      process
    end

    def stop
      @stopped = true
      terminate_child
    end

    def check
      raise Stopped.new if stopped
    end

    def terminate_child
      if process = @child
        terminate(process, graceful: true)
        spawn do
          sleep 2.seconds
          terminate(process, graceful: false) if @child == process
        end
      end
    end

    private def terminate(process, graceful)
      process.terminate(graceful: graceful)
    rescue IO::Error
      # The owned child may have exited between notification and termination.
    end

    private def terminate_and_reap(process : Process) : Nil
      terminate(process, graceful: false)
      process.wait
    rescue IO::Error
      # A child that exited during the stop race may already have been reaped.
    end

    def pause(seconds : Int32)
      (seconds * 10).times do
        check
        sleep 100.milliseconds
      end
    end
  end

  class Reporter
    def initialize(@io : IO = STDOUT)
    end

    def emit(
      state : String,
      reason : String? = nil,
      source_id : String? = nil,
    )
      @io.puts({state: state, reason: reason, source_id: source_id}.to_json)
      @io.flush
    end
  end

  class Config
    getter ship : String
    getter tinrelay : String
    getter codex_home : String
    getter home : String
    getter routing_file : String
    getter timeout : Time::Span
    getter? deref : Bool

    def initialize(
      @ship,
      tinrelay = "tinrelay",
      @codex_home = ENV["CODEX_HOME"]? || Path.home.join(".codex").to_s,
      @home = Path.home.to_s,
      routing_file : String? = nil,
      @timeout : Time::Span = CodexBridge::Client::DEFAULT_TIMEOUT,
      @deref = true,
    )
      raise Blocked.new("invalid_timeout") if @timeout < 0.seconds
      unless Tinrelay::Names::SHIP.matches?(ship)
        raise Blocked.new("invalid_ship")
      end
      @paths = Tinrelay::LocalPaths.new(ship, home)
      @tinrelay = Process.find_executable(tinrelay) ||
                  raise Blocked.new("tinrelay_executable_unavailable")
      @routing_file = routing_file || @paths.codex_addresses
      if routing_file && !Path.new(routing_file).absolute?
        raise Blocked.new("routing_file_must_be_absolute")
      end
    end

    def lock_path
      File.join(home, ".local", "share", "tinrelay-codex-bridge", "locks", "#{ship}.lock")
    end

    def local_delivery_lock_path
      @paths.local_delivery_lock
    end

    def pending_target_path
      @paths.pending_target
    end
  end

  class Event
    getter raw : String
    getter id : String
    getter kind : String
    getter wrapper : String
    getter name : String?

    def initialize(@raw)
      @id, @kind, @wrapper, @name = validate(raw)
    end

    private def validate(raw) : Tuple(String, String, String, String?)
      value = JSON.parse(raw)
      unless value.as_h["contract"].as_s == "tinrelay-radio-wait-v2"
        raise Blocked.new("invalid_radio_contract")
      end
      id = value.as_h["source_id"].as_s
      kind = value.as_h["kind"].as_s
      unless Tinrelay::Ids::SOURCE_KINDS.includes?(kind)
        raise Blocked.new("invalid_event_kind")
      end
      raise Blocked.new("invalid_source_id") unless Tinrelay::Ids.source?(kind, id)
      wrapper = value.as_h["wrapper"].as_s
      raise Blocked.new("invalid_wrapper") if wrapper.empty?
      name = value.as_h["name"]?
      parsed_name = name.try(&.as_s?)
      if kind == "transmission"
        raise Blocked.new("invalid_event_name") unless name && parsed_name
      elsif name && !name.raw.nil?
        raise Blocked.new("invalid_event_name")
      end
      allowed = {"contract", "source_id", "kind", "wrapper", "name"}
      unless value.as_h.keys.all? { |key| allowed.includes?(key) }
        raise Blocked.new("unknown_event_field")
      end
      {id, kind, wrapper, parsed_name}
    rescue JSON::ParseException | TypeCastError | KeyError
      raise Blocked.new("invalid_radio_event")
    end
  end
end

require "./child"
require "./address_book"
require "./pending_target"
require "./runner"
