module Tinrelay
  class SubmissionWindow
    @mutex = Mutex.new
    @attempts = {} of String => Array(Int64)

    def initialize(@limit : Int32, @period_seconds : Int64)
    end

    def allow?(ship : String, now : Int64 = Time.utc.to_unix) : Bool
      admit(ship, now).nil?
    end

    # Nil means admitted; a positive value is the number of seconds until the
    # oldest attempt leaves this rolling window.
    def admit(ship : String, now : Int64 = Time.utc.to_unix) : Int32?
      @mutex.synchronize do
        cutoff = now - @period_seconds
        prune_inactive(cutoff)
        timestamps = @attempts[ship]?
        if timestamps
          timestamps.reject! { |timestamp| timestamp <= cutoff }
          @attempts.delete(ship) if timestamps.empty?
        end
        timestamps ||= [] of Int64
        if timestamps.size >= @limit
          return Math.max(timestamps.first + @period_seconds - now, 1_i64).to_i
        end
        timestamps << now
        @attempts.delete(ship)
        @attempts[ship] = timestamps
        nil
      end
    end

    private def prune_inactive(cutoff : Int64) : Nil
      # Accepted activity moves a ship to the end, so only the expired oldest
      # prefix is visited and each inactive identity is removed once.
      while oldest = @attempts.first?
        ship, timestamps = oldest
        break unless timestamps.empty? || timestamps.last <= cutoff
        @attempts.delete(ship)
      end
    end
  end
end
