require "../tinrelay/atomic_private_file"

module TinrelayCodexBridge
  enum DeliveryState
    Ready
    Delivered
    ReceiptUnknown
  end

  record PendingTargetBinding,
    kind : String,
    source_id : String,
    task_id : String,
    state : DeliveryState

  class PendingTarget
    MAX_BYTES = 1024

    def initialize(@path : String)
    end

    def load : PendingTargetBinding?
      return unless File.exists?(@path)
      bytes = File.open(@path) do |file|
        buffer = IO::Memory.new
        count = IO.copy(file, buffer, MAX_BYTES + 1)
        raise Blocked.new("pending_target_too_large") if count > MAX_BYTES
        buffer.to_s
      end
      value = JSON.parse(bytes).as_h
      unless value.keys.sort == ["kind", "source_id", "state", "task_id"]
        raise Blocked.new("invalid_pending_target")
      end
      kind = value["kind"].as_s
      source_id = value["source_id"].as_s
      task_id = value["task_id"].as_s
      state = parse_state(value["state"].as_s)
      raise Blocked.new("invalid_pending_target") unless valid_identity?(kind, source_id)
      raise Blocked.new("invalid_pending_target") unless valid_task_id?(task_id)
      PendingTargetBinding.new(kind, source_id, task_id, state)
    rescue File::Error
      raise Blocked.new("pending_target_unreadable")
    rescue JSON::ParseException | TypeCastError | KeyError
      raise Blocked.new("invalid_pending_target")
    end

    def bind(kind : String, source_id : String, task_id : String) : PendingTargetBinding
      if current = load
        unless current.kind == kind && current.source_id == source_id
          raise Blocked.new("pending_target_conflict")
        end
        return current
      end
      write(PendingTargetBinding.new(kind, source_id, task_id, DeliveryState::Ready))
    end

    def replace(
      current : PendingTargetBinding,
      task_id = current.task_id,
      state = current.state,
    ) : PendingTargetBinding
      persisted = load || raise Blocked.new("pending_target_missing")
      raise Blocked.new("pending_target_conflict") unless persisted == current
      write(PendingTargetBinding.new(current.kind, current.source_id, task_id, state))
    end

    def clear(kind : String, source_id : String)
      current = load || return
      unless current.kind == kind && current.source_id == source_id
        raise Blocked.new("pending_target_conflict")
      end
      Tinrelay::PrivateStorage.delete_replay_safe(@path)
    rescue File::Error
      raise Blocked.new("pending_target_unwritable")
    end

    private def write(binding)
      Tinrelay::AtomicPrivateFile.write(
        @path,
        {
          kind:      binding.kind,
          source_id: binding.source_id,
          task_id:   binding.task_id,
          state:     state_name(binding.state),
        }.to_json + '\n'
      )
      binding
    end

    private def valid_identity?(kind, value)
      case kind
      when "transmission", "hail"
        SOURCE_UUID.matches?(value)
      when "rejected_transmission"
        /\Atr_[0-9a-f]{32}\z/.matches?(value)
      else
        false
      end
    end

    private def valid_task_id?(value)
      /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/.matches?(value)
    end

    private def parse_state(value)
      case value
      when "ready"           then DeliveryState::Ready
      when "delivered"       then DeliveryState::Delivered
      when "receipt_unknown" then DeliveryState::ReceiptUnknown
      else                        raise Blocked.new("invalid_pending_target")
      end
    end

    private def state_name(state)
      case state
      when DeliveryState::Ready          then "ready"
      when DeliveryState::Delivered      then "delivered"
      when DeliveryState::ReceiptUnknown then "receipt_unknown"
      else                                    raise Blocked.new("invalid_pending_target")
      end
    end
  end
end
