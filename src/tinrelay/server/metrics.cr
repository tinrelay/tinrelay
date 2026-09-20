module Tinrelay
  class Metrics
    REGISTRATION_OUTCOMES = %w[
      accepted rate_limited cidr_denied closed policy_changed capacity invalid conflict
    ]
    TRANSMISSION_OUTCOMES      = %w[direct queued acknowledged expired rejected]
    TRANSMISSION_BYTE_OUTCOMES = %w[direct queued]
    HAIL_OUTCOMES              = %w[accepted collected allowed expired rejected]
    RADIO_WAIT_OUTCOMES        = %w[transmission hail contact_update timeout disconnect error]
    RELOAD_OUTCOMES            = %w[accepted rejected]
    CLEANUP_KINDS              = %w[
      transmissions_expired transmissions_deleted hails_expired
      relationships_deleted transitions_deleted errors
    ]
    ACK_LATENCY_BUCKETS = [1_i64, 5_i64, 15_i64, 60_i64, 300_i64, 3_600_i64, 86_400_i64]

    getter process_started_at : Int64

    def initialize(@process_started_at = Time.utc.to_unix)
      @mutex = Mutex.new
      @counters = Hash(Tuple(Symbol, String), Int64).new(0_i64)
      @ack_latency_buckets = Hash(Int64, Int64).new(0_i64)
      @ack_latency_sum = 0_i64
      @ack_latency_count = 0_i64
      @configuration_generation = 1_i64
    end

    def registration(outcome : String, count = 1_i64) : Nil
      increment(:registration, outcome, REGISTRATION_OUTCOMES, count)
    end

    def transmission(outcome : String, count = 1_i64) : Nil
      increment(:transmission, outcome, TRANSMISSION_OUTCOMES, count)
    end

    def transmission_bytes(outcome : String, count : Int64) : Nil
      increment(:transmission_bytes, outcome, TRANSMISSION_BYTE_OUTCOMES, count)
    end

    def acknowledgement_latency(seconds : Int64) : Nil
      @mutex.synchronize do
        ACK_LATENCY_BUCKETS.each do |upper_bound|
          @ack_latency_buckets[upper_bound] += 1 if seconds <= upper_bound
        end
        @ack_latency_sum += seconds
        @ack_latency_count += 1
      end
    end

    def hail(outcome : String, count = 1_i64) : Nil
      increment(:hail, outcome, HAIL_OUTCOMES, count)
    end

    def radio_wait(outcome : String, count = 1_i64) : Nil
      increment(:radio_wait, outcome, RADIO_WAIT_OUTCOMES, count)
    end

    def configuration_reload(outcome : String) : Nil
      raise ArgumentError.new("unknown metrics outcome") unless RELOAD_OUTCOMES.includes?(outcome)
      @mutex.synchronize do
        @configuration_generation += 1 if outcome == "accepted"
        @counters[{:configuration_reload, outcome}] += 1
      end
    end

    def cleanup(result) : Nil
      increment(:cleanup, "transmissions_expired", CLEANUP_KINDS, result[:expired].to_i64)
      increment(:cleanup, "transmissions_deleted", CLEANUP_KINDS, result[:deleted].to_i64)
      increment(:cleanup, "hails_expired", CLEANUP_KINDS, result[:hails_deleted].to_i64)
      increment(
        :cleanup, "relationships_deleted", CLEANUP_KINDS,
        result[:relationships_deleted].to_i64
      )
      increment(
        :cleanup, "transitions_deleted", CLEANUP_KINDS,
        result[:transitions_deleted].to_i64
      )
      transmission("expired", result[:expired].to_i64)
      hail("expired", result[:hails_deleted].to_i64)
    end

    def cleanup_error : Nil
      increment(:cleanup, "errors", CLEANUP_KINDS, 1_i64)
    end

    def render(store : Store, handoffs : DirectHandoff,
               now = Time.utc.to_unix) : String
      database = store.metrics_snapshot(now)
      process = @mutex.synchronize do
        {
          counters:                 @counters.dup,
          ack_latency_buckets:      @ack_latency_buckets.dup,
          ack_latency_sum:          @ack_latency_sum,
          ack_latency_count:        @ack_latency_count,
          configuration_generation: @configuration_generation,
        }
      end
      String.build do |io|
        gauge(io, "tinrelay_process_start_time_seconds", process_started_at)
        build_info(io)
        gauge(
          io, "tinrelay_configuration_generation",
          process[:configuration_generation]
        )
        io << "# TYPE tinrelay_registered_ships gauge\n"
        database[:ships].each do |state, count|
          sample(io, "tinrelay_registered_ships", count, "state", state)
        end
        io << "# TYPE tinrelay_relationships gauge\n"
        database[:relationships].each do |state, count|
          sample(io, "tinrelay_relationships", count, "state", state)
        end
        gauge(io, "tinrelay_radio_waits_active", handoffs.waiting_count)
        gauge(io, "tinrelay_queued_transmissions", database[:queued_transmissions])
        gauge(io, "tinrelay_queued_hails", database[:queued_hails])
        gauge(
          io, "tinrelay_oldest_queued_transmission_age_seconds",
          database[:oldest_transmission_age]
        )
        gauge(io, "tinrelay_oldest_queued_hail_age_seconds", database[:oldest_hail_age])
        gauge(io, "tinrelay_retained_ciphertext_bytes", database[:ciphertext_bytes])
        gauge(io, "tinrelay_sqlite_files_bytes", database[:sqlite_files_bytes])
        io << "# TYPE tinrelay_permanent_metadata_items gauge\n"
        sample(io, "tinrelay_permanent_metadata_items", database[:metadata_used], "state", "used")
        sample(io, "tinrelay_permanent_metadata_items", database[:metadata_limit], "state", "limit")
        sample(
          io, "tinrelay_permanent_metadata_items", database[:metadata_headroom],
          "state", "headroom"
        )
        counter_family(
          io, process[:counters], :registration, "tinrelay_registrations_total",
          REGISTRATION_OUTCOMES
        )
        counter_family(
          io, process[:counters], :transmission, "tinrelay_transmissions_total",
          TRANSMISSION_OUTCOMES
        )
        counter_family(
          io, process[:counters], :transmission_bytes,
          "tinrelay_transmission_ciphertext_bytes_total", TRANSMISSION_BYTE_OUTCOMES
        )
        acknowledgement_latency(io, process)
        counter_family(
          io, process[:counters], :hail, "tinrelay_hails_total", HAIL_OUTCOMES
        )
        counter_family(
          io, process[:counters], :radio_wait,
          "tinrelay_radio_waits_total", RADIO_WAIT_OUTCOMES
        )
        counter_family(
          io, process[:counters], :configuration_reload,
          "tinrelay_configuration_reloads_total", RELOAD_OUTCOMES
        )
        counter_family(
          io, process[:counters], :cleanup, "tinrelay_cleanup_items_total", CLEANUP_KINDS
        )
      end
    end

    private def increment(family : Symbol, outcome : String,
                          allowed : Array(String), count : Int64) : Nil
      raise ArgumentError.new("unknown metrics outcome") unless allowed.includes?(outcome)
      return if count == 0
      @mutex.synchronize { @counters[{family, outcome}] += count }
    end

    private def gauge(io : IO, name : String, value) : Nil
      io << "# TYPE " << name << " gauge\n"
      io << name << ' ' << value << '\n'
    end

    private def build_info(io : IO) : Nil
      io << "# TYPE tinrelay_build_info gauge\n"
      io << "tinrelay_build_info{build=\"" << escape_label(BUILD_LABEL)
      io << "\",protocol=\"" << PROTOCOL << "\"} 1\n"
    end

    private def acknowledgement_latency(io : IO, process) : Nil
      name = "tinrelay_acknowledgement_latency_seconds"
      io << "# TYPE " << name << " histogram\n"
      ACK_LATENCY_BUCKETS.each do |upper_bound|
        sample(io, "#{name}_bucket", process[:ack_latency_buckets][upper_bound],
          "le", upper_bound.to_s)
      end
      sample(io, "#{name}_bucket", process[:ack_latency_count], "le", "+Inf")
      io << name << "_sum " << process[:ack_latency_sum] << '\n'
      io << name << "_count " << process[:ack_latency_count] << '\n'
    end

    private def escape_label(value : String) : String
      value.gsub('\\', "\\\\").gsub('"', "\\\"").gsub('\n', "\\n")
    end

    private def sample(io : IO, name : String, value,
                       label : String, label_value : String) : Nil
      io << name << '{' << label << "=\"" << label_value << "\"} " << value << '\n'
    end

    private def counter_family(io : IO,
                               counters : Hash(Tuple(Symbol, String), Int64),
                               family : Symbol, name : String,
                               outcomes : Array(String)) : Nil
      io << "# TYPE " << name << " counter\n"
      outcomes.each do |outcome|
        sample(io, name, counters[{family, outcome}], "outcome", outcome)
      end
    end
  end
end
