module TinrelayCodexBridge
  class Runner
    IMMEDIATE_RETRY_SECONDS  = 2
    IMMEDIATE_RETRY_WINDOW   = 5 * 60
    RESPONSIVE_RETRY_SECONDS = 5
    RESPONSIVE_RETRY_WINDOW  = 10 * 60
    BACKGROUND_RETRY_SECONDS = 15
    BACKGROUND_RETRY_WINDOW  = 60 * 60
    IDLE_RETRY_SECONDS       = 60

    def initialize(@config : Config, @control = Control.new, @reporter = Reporter.new)
      @child = Child.new(@config, @control)
      @address_book = AddressBook.new(@config.routing_file)
      @pending_target = PendingTarget.new(@config.pending_target_path)
      @desktop = CodexBridge::Client.new(
        @config.codex_home,
        timeout: @config.timeout
      )
    end

    def check
      @child.version
      @address_book.check
      connection = CodexBridge.discover(@config.codex_home)
      raise DeliveryUnavailable.new("codex_app_tools_unavailable") unless connection
      @reporter.emit("ready", "desktop_delivery_available")
    end

    def run
      with_lock(@config.lock_path, AlreadyRunning.new("bridge_already_running")) do
        with_lock(
          @config.local_delivery_lock_path,
          Blocked.new("local_delivery_already_owned")
        ) do
          @child.version
          loop do
            @control.check
            pending = @pending_target.load
            if pending && @child.routed?(pending.kind, pending.source_id)
              @pending_target.clear(pending.kind, pending.source_id)
              next
            end
            @reporter.emit("listening")
            deliver(@child.wait_event, pending)
          end
        end
      end
    end

    private def with_lock(path, error, &)
      directory = File.dirname(path)
      Dir.mkdir_p(directory, mode: 0o700)
      Tinrelay::PrivateStorage.secure(directory, 0o700)
      File.open(path, "a", perm: 0o600) do |lock|
        Tinrelay::PrivateStorage.secure(path, 0o600)
        begin
          lock.flock_exclusive(false)
        rescue IO::Error
          raise error
        end
        yield
      end
    end

    private def deliver(event, pending : PendingTargetBinding?)
      if pending && (pending.kind != event.kind || pending.source_id != event.id)
        unless @child.routed?(pending.kind, pending.source_id)
          raise Blocked.new("pending_target_conflict")
        end
        @pending_target.clear(pending.kind, pending.source_id)
        pending = nil
      end
      if @child.routed?(event)
        @pending_target.clear(event.kind, event.id) if pending
        return
      end

      target = pending || @pending_target.bind(
        event.kind, event.id, @address_book.resolve(event)
      )
      case target.state
      when DeliveryState::Delivered
        finish_delivery(event, target, "accepted_before_restart")
      when DeliveryState::ReceiptUnknown
        raise Blocked.new("delivery_receipt_unknown")
      when DeliveryState::Ready
        send(event, target)
      end
    end

    private def send(event, target)
      started = Time.instant
      message = @config.deref? ? @child.dereference(event) : event.wrapper
      loop do
        @control.check
        begin
          @desktop.send_message(target.task_id, message)
          target = @pending_target.replace(target, state: DeliveryState::Delivered)
          finish_delivery(event, target)
          return
        rescue ex : CodexBridge::NotReceived
          @reporter.emit("waiting_for_recipient", ex.reason, source_id: event.id)
          @control.pause(retry_seconds(Time.instant - started))
        rescue ex : CodexBridge::ReceiptUnknown
          @pending_target.replace(target, state: DeliveryState::ReceiptUnknown)
          @reporter.emit("delivery_receipt_unknown", ex.reason, source_id: event.id)
          raise Blocked.new("delivery_receipt_unknown")
        end
      end
    end

    private def finish_delivery(event, target, reason = nil)
      @reporter.emit("accepted", reason, source_id: event.id)
      @child.mark_routed(event)
      @pending_target.clear(target.kind, target.source_id)
    end

    private def retry_seconds(elapsed)
      seconds = elapsed.total_seconds
      return IMMEDIATE_RETRY_SECONDS if seconds < IMMEDIATE_RETRY_WINDOW
      return RESPONSIVE_RETRY_SECONDS if seconds < RESPONSIVE_RETRY_WINDOW
      return BACKGROUND_RETRY_SECONDS if seconds < BACKGROUND_RETRY_WINDOW
      IDLE_RETRY_SECONDS
    end
  end
end
