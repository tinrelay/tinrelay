module TinrelayCodexBridge
  class Child
    MAX_BYTES = 64 * 1024

    def initialize(@config : Config, @control : Control)
    end

    # Pipes are owned here, so Process#wait cannot close them before the readers
    # drain. Capture is bounded and never copied into diagnostics.
    def execute(args : Array(String)) : Tuple(Process::Status, String, String)
      @control.check
      stdout_read, stdout_write = IO.pipe
      stderr_read, stderr_write = IO.pipe
      process = Process.new(
        @config.tinrelay,
        args,
        # The bridge process holds the local-delivery lock across native delivery.
        # Its owned TinRelay child is the only process allowed to select under it.
        env: ENV.to_h.merge({
          "TINRELAY_LOCAL_DELIVERY_OWNER" => "tinrelay-codex-bridge-v1",
        }),
        input: Process::Redirect::Close,
        output: stdout_write,
        error: stderr_write,
      )
      @control.child = process
      stdout_write.close
      stderr_write.close
      output = capture(stdout_read)
      error = capture(stderr_read)
      result = process.wait
      @control.child = nil
      @control.check
      {result, captured(output), captured(error)}
    rescue IO::Error
      raise Blocked.new("tinrelay_process_io_failure")
    ensure
      stdout_write.try(&.close)
      stderr_write.try(&.close)
      stdout_read.try(&.close)
      stderr_read.try(&.close)
    end

    private def capture(io : IO)
      channel = Channel(String | Exception).new(1)
      spawn do
        begin
          buffer = IO::Memory.new
          scratch = Bytes.new(4096)
          while (count = io.read(scratch)) > 0
            raise Blocked.new("tinrelay_output_too_large") if buffer.size + count > MAX_BYTES
            buffer.write(scratch[0, count])
          end
          channel.send(buffer.to_s)
        rescue ex
          @control.terminate_child
          channel.send(ex)
        end
      end
      channel
    end

    private def captured(channel)
      select
      when value = channel.receive
        raise Blocked.new("tinrelay_capture_failure") if value.is_a?(Exception)
        value
      when timeout(1.second)
        raise Blocked.new("tinrelay_pipe_not_closed")
      end
    end

    def version
      result, output, _ = execute(["version"])
      unless result.success? && output.starts_with?("tinrelay ")
        raise Blocked.new("tinrelay_version_failed")
      end
    end

    def wait_event
      result, output, _ = execute(["radio", "wait", "--local", "--ship", @config.ship])
      raise Blocked.new("tinrelay_local_wait_failed") unless result.success?
      raise Blocked.new("invalid_radio_output") unless output.lines.size == 1
      Event.new(output.strip)
    end

    def routed?(event : Event)
      routed, kind = status(event.kind, event.id)
      raise Blocked.new("status_kind_mismatch") unless kind == event.kind
      routed
    end

    def dereference(event : Event) : String
      return event.wrapper unless event.kind == "transmission"
      result, output, _ = execute([
        "inbox", "show", event.kind, event.id, "--ship", @config.ship,
      ])
      raise Blocked.new("tinrelay_inbox_show_failed") unless result.success?
      value = JSON.parse(output)
      unless value["contract"].as_s == "tinrelay-inspected-inbox-v2" &&
             value["kind"].as_s == "transmission" &&
             value["transmission_id"].as_s == event.id &&
             value["state"].as_s == "pending"
        raise Blocked.new("invalid_inbox_output")
      end

      signed = value["signed_transmission"]
      received_at = value["received_at"].as_i64
      raise Blocked.new("invalid_inbox_output") unless received_at > 0
      sender_ship = value["sender_ship"].as_s
      recipient_ship = value["recipient_ship"].as_s
      attention_label = value["attention_label"].as_s
      author_label = optional_string(value["author_label"]?)
      unless recipient_ship == @config.ship && attention_label == event.name &&
             signed["sender_ship"].as_s == sender_ship &&
             signed["recipient_ship"].as_s == recipient_ship &&
             signed["to_label"].as_s == attention_label &&
             optional_string(signed["from_label"]?) == author_label
        raise Blocked.new("invalid_inbox_output")
      end

      delivery = {
        contract:        "tinrelay-message-delivery-v2",
        kind:            "transmission",
        transmission_id: event.id,
        local_ship:      @config.ship,
        received_at:     received_at,
        sender_ship:     sender_ship,
        attention_label: attention_label,
        author_label:    author_label,
        body:            signed["body"].as_s,
      }
      "TINRELAY MESSAGE DELIVERY\n#{delivery.to_json}"
    rescue JSON::ParseException | TypeCastError | KeyError
      raise Blocked.new("invalid_inbox_output")
    end

    def routed?(kind : String, source_id : String)
      status(kind, source_id).first
    end

    def mark_routed(event : Event)
      result, output, _ = execute([
        "radio", "routed", event.kind, event.id, "--ship", @config.ship,
      ])
      raise Blocked.new("tinrelay_routed_failed") unless result.success?
      value = JSON.parse(output).as_h
      unless value.keys.sort == ["kind", "source_id", "state"] &&
             value["state"].as_s == "routed" &&
             value["kind"].as_s == event.kind &&
             value["source_id"].as_s == event.id
        raise Blocked.new("invalid_routed_output")
      end
    rescue JSON::ParseException | TypeCastError | KeyError
      raise Blocked.new("invalid_routed_output")
    end

    private def status(kind : String, source_id : String)
      result, output, _ = execute([
        "radio", "status", kind, source_id, "--ship", @config.ship,
      ])
      raise Blocked.new("tinrelay_status_failed") unless result.success?
      value = JSON.parse(output)
      unless value.as_h["source_id"].as_s == source_id &&
             value.as_h["kind"].as_s == kind &&
             {"transmission", "hail", "rejected_transmission"}.includes?(kind)
        raise Blocked.new("invalid_radio_status")
      end
      routed = case value.as_h["state"].as_s
               when "routed"  then true
               when "pending" then false
               else                raise Blocked.new("invalid_radio_status")
               end
      {routed, kind}
    rescue JSON::ParseException | TypeCastError | KeyError
      raise Blocked.new("invalid_radio_status")
    end

    private def optional_string(value : JSON::Any?) : String?
      return unless value && !value.raw.nil?
      value.as_s
    end
  end
end
