require "./tinrelay/server"

module Tinrelay
  module ServerCLI
    def self.run(argv : Array(String)) : Nil
      command = argv.shift? || "help"
      case command
      when "help", "--help", "-h"
        puts HELP
      when "version", "--version", "-v"
        puts "tinrelayd #{VERSION} protocol #{PROTOCOL} build #{BUILD_LABEL}"
      when "migrate"
        database = Database.new(required(argv, "--database"))
        database.close
        no_extra!(argv)
        puts({state: "migrated"}.to_json)
      when "cleanup"
        database = Database.new(required(argv, "--database"))
        result = Store.new(database).cleanup
        database.close
        no_extra!(argv)
        puts result.to_json
      when "serve"
        serve(argv)
      else
        raise Invalid.new("unknown tinrelayd command: #{command}")
      end
    rescue ex : Error
      STDERR.puts({error: ex.class.name.split("::").last.underscore, message: ex.message}.to_json)
      exit 2
    end

    private def self.serve(argv) : Nil
      database_path = required(argv, "--database")
      bind = extract(argv, "--bind") || "127.0.0.1"
      port = (extract(argv, "--port") || "8787").to_i
      configuration_path = extract(argv, "--config") || extract(argv, "-c")
      threads = ServerRuntime.thread_count(extract(argv, "--threads"))
      permanent_metadata_limit = numeric(
        extract(argv, "--permanent-metadata-limit"),
        "--permanent-metadata-limit",
        DEFAULT_PERMANENT_METADATA_LIMIT
      )
      no_extra!(argv)
      ServerRuntime.enable_multicore(threads)
      config = ServerConfig.new(
        bind, port, database_path, threads, permanent_metadata_limit,
        configuration_path
      )
      api = API.new(config)
      server = HTTP::Server.new(api.handler)
      server.bind_tcp(bind, port)
      stopping = false
      stop = -> {
        unless stopping
          stopping = true
          STDERR.puts({event: "shutdown_requested"}.to_json)
          server.close
        end
      }
      Process.on_terminate { stop.call }
      reload_requests = Channel(Nil).new(1)
      {% if flag?(:darwin) || flag?(:linux) %}
        Signal::HUP.trap do
          select
          when reload_requests.send(nil)
          else
          end
        end
      {% elsif flag?(:win32) %}
        # Windows service control has no SIGHUP equivalent.
      {% else %}
        {% raise "TinRelay does not support this platform" %}
      {% end %}
      spawn do
        loop do
          reload_requests.receive
          begin
            api.reload_configuration
            api.metrics.configuration_reload("accepted")
            STDERR.puts({event: "configuration_reloaded"}.to_json)
          rescue ex
            api.metrics.configuration_reload("rejected")
            STDERR.puts({
              event:   "configuration_reload_failed",
              error:   ex.class.name,
              message: bounded_message(ex),
            }.to_json)
          end
        end
      end
      spawn do
        cleanup_delay = 60.seconds
        loop do
          sleep cleanup_delay
          break if stopping
          result = api.store.cleanup
          api.metrics.cleanup(result)
          if result.values.any?(&.> 0)
            STDERR.puts({
              event:   "cleanup",
              expired: result[:expired],
              deleted: result[:deleted],
            }.to_json)
          end
          cleanup_delay = if result[:deleted] == Store::CLEANUP_BATCH_SIZE
                            1.second
                          else
                            60.seconds
                          end
        rescue ex
          api.metrics.cleanup_error
          STDERR.puts({event: "cleanup_failed", error: ex.class.name}.to_json)
          cleanup_delay = 60.seconds
        end
      end
      STDERR.puts({
        event: "ready", bind: bind, port: port, protocol: PROTOCOL,
        threads: threads,
        permanent_metadata_used: api.store.permanent_metadata_usage,
        permanent_metadata_limit: permanent_metadata_limit,
      }.to_json)
      server.listen
    ensure
      api.try(&.close)
      STDERR.puts({event: "stopped"}.to_json)
    end

    private def self.extract(argv : Array(String), name : String) : String?
      index = argv.index(name)
      return nil unless index
      raise Invalid.new("#{name} requires a value") unless index + 1 < argv.size
      argv.delete_at(index)
      argv.delete_at(index)
    end

    private def self.required(argv, name) : String
      extract(argv, name) || raise Invalid.new("#{name} is required")
    end

    private def self.numeric(value : String?, name : String,
                             default : Int64) : Int64
      return default unless value
      value.to_i64? || raise Invalid.new("#{name} must be an integer")
    end

    private def self.bounded_message(error : Exception) : String
      message = error.message || "configuration reload failed"
      message.size > 240 ? "#{message[0, 240]}…" : message
    end

    private def self.no_extra!(argv) : Nil
      raise Invalid.new("unexpected arguments: #{argv.join(' ')}") unless argv.empty?
    end

    HELP = {{ read_file("templates/tinrelayd-help.txt") }}
  end
end

Tinrelay::ServerCLI.run(ARGV.dup)
