module Tinrelay
  class TransmissionTokenBuckets
    BYTE_REFILL_PER_SECOND = 2 * 1024
    BYTE_CAPACITY          = 128 * 1024
    MESSAGE_CAPACITY       = 32
    FULL_REFILL_SECONDS    = 64

    private class State
      property byte_tokens : Float64
      property message_tokens : Float64
      property updated_at : Time::Instant

      def initialize(@updated_at)
        @byte_tokens = BYTE_CAPACITY.to_f
        @message_tokens = MESSAGE_CAPACITY.to_f
      end
    end

    @mutex = Mutex.new
    @buckets = {} of String => State

    # Nil means admitted. A positive result is the whole-second wait until both
    # the byte and message buckets can admit this transmission together.
    def admit(source : String, ciphertext_bytes : Int32,
              now : Time::Instant = Time.instant) : Int32?
      @mutex.synchronize do
        prune_full(now)
        state = @buckets[source]? || State.new(now)
        elapsed = Math.max((now - state.updated_at).total_seconds, 0.0)
        state.byte_tokens = Math.min(
          BYTE_CAPACITY.to_f,
          state.byte_tokens + elapsed * BYTE_REFILL_PER_SECOND
        )
        state.message_tokens = Math.min(
          MESSAGE_CAPACITY.to_f,
          state.message_tokens + elapsed
        )
        state.updated_at = now
        @buckets.delete(source)
        @buckets[source] = state

        byte_wait = (ciphertext_bytes - state.byte_tokens) / BYTE_REFILL_PER_SECOND
        message_wait = 1.0 - state.message_tokens
        wait = Math.max(byte_wait, message_wait)
        return Math.max(wait.ceil.to_i, 1) if wait > 0

        state.byte_tokens -= ciphertext_bytes
        state.message_tokens -= 1
        nil
      end
    end

    private def prune_full(now : Time::Instant) : Nil
      while oldest = @buckets.first?
        source, state = oldest
        break unless now - state.updated_at >= FULL_REFILL_SECONDS.seconds
        @buckets.delete(source)
      end
    end
  end
end
