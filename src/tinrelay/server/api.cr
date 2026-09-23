require "set"

module Tinrelay
  class ServerConfig
    getter bind : String
    getter port : Int32
    getter database_path : String
    getter database_connections : Int32
    getter permanent_metadata_limit : Int64
    getter configuration_path : String?

    def initialize(@bind = "127.0.0.1", @port = 8787,
                   @database_path = "tinrelay.db",
                   @database_connections = System.cpu_count,
                   @permanent_metadata_limit = DEFAULT_PERMANENT_METADATA_LIMIT,
                   @configuration_path = nil)
    end
  end

  class RuntimeSnapshot
    getter registration_allowances : RegistrationAllowances
    getter client_address_policy : ClientAddressPolicy
    getter? request_logging : Bool
    @registration_deny_cidrs : Array(IPNetwork)
    @rate_limit_exclusions : Set(String)

    def initialize(@registration_allowances,
                   registration_deny_cidrs : Array(IPNetwork),
                   @client_address_policy,
                   rate_limit_exclusions : Array(String),
                   @request_logging)
      @registration_deny_cidrs = registration_deny_cidrs.dup
      @rate_limit_exclusions = Set.new(rate_limit_exclusions)
    end

    def registration_deny_cidrs : Array(IPNetwork)
      @registration_deny_cidrs.dup
    end

    def rate_limit_excluded?(ship : String) : Bool
      @rate_limit_exclusions.includes?(ship)
    end

    def registration_source(
      peer : Socket::Address?,
      headers : HTTP::Headers,
    ) : NamedTuple(bucket: String?, cidr_denied: Bool)
      address = client_address_policy.resolve(peer, headers)
      if @registration_deny_cidrs.any?(&.includes?(address))
        {bucket: nil, cidr_denied: true}
      else
        {bucket: LiteralIP.source_bucket(address), cidr_denied: false}
      end
    rescue Invalid
      {bucket: nil, cidr_denied: false}
    end

    def source_bucket(peer : Socket::Address?, headers : HTTP::Headers) : String
      LiteralIP.source_bucket(client_address_policy.resolve(peer, headers))
    end
  end

  class API
    MAX_REQUEST_BYTES             = 64 * 1024
    ACCEPTANCE_TARGET             = 250.milliseconds
    RADIO_WAIT_HEARTBEAT_INTERVAL = 25.seconds
    getter config : ServerConfig
    getter database : Database
    getter store : Store
    getter handoffs : DirectHandoff
    getter metrics : Metrics
    getter transmission_buckets : TransmissionTokenBuckets
    getter hail_window : SubmissionWindow
    @runtime_snapshot : Atomic(RuntimeSnapshot)

    def initialize(@config,
                   @radio_wait_heartbeat_interval = RADIO_WAIT_HEARTBEAT_INTERVAL)
      @database = Database.new(config.database_path, config.database_connections)
      @store = Store.new(database, config.permanent_metadata_limit)
      snapshot = begin
        load_runtime_snapshot(true)
      rescue ex
        database.close
        raise ex
      end
      @runtime_snapshot = Atomic(RuntimeSnapshot).new(snapshot)
      @handoffs = DirectHandoff.new
      @metrics = Metrics.new
      @transmission_buckets = TransmissionTokenBuckets.new
      @hail_window = SubmissionWindow.new(Store::MAX_HAILS_PER_DAY, 24 * 60 * 60)
    end

    def runtime_snapshot : RuntimeSnapshot
      @runtime_snapshot.get(:acquire)
    end

    def reload_configuration : Nil
      candidate = load_runtime_snapshot(false)
      store.synchronize_claim_commit do
        @runtime_snapshot.set(candidate, :release)
      end
    end

    def handler
      HTTP::Handler::HandlerProc.new do |context|
        started = Time.instant
        status = 500
        begin
          status = route(context)
        rescue ex : JSON::ParseException
          status = error(context, 400, "invalid_json", "request JSON is invalid")
        rescue ex : Invalid
          status = error(context, 400, "invalid", ex.message || "invalid request")
        rescue ex : Unauthorized
          status = error(context, 401, "unauthorized", ex.message || "unauthorized")
        rescue ex : NotFound
          status = error(context, 404, "not_found", ex.message || "not found")
        rescue ex : Conflict
          status = error(context, 409, "conflict", ex.message || "conflict")
        rescue ex : Expired
          status = error(context, 410, "expired", ex.message || "expired")
        rescue ex : TransmissionLimited
          context.response.headers["Retry-After"] = ex.retry_after_seconds.to_s
          status = error(
            context, 429, "transmission_limited",
            "relay is receiving too much transmission traffic"
          )
        rescue ex : RotationLimited
          context.response.headers["Retry-After"] = ex.retry_after_seconds.to_s
          status = json(
            context, 429,
            RotationLimitEvidence.new(
              "rotation_limited", ex.retry_after_seconds
            ).to_json
          )
        rescue ex : Unavailable
          status = error(context, 503, "unavailable", ex.message || "unavailable")
        rescue ex : HTTP::Server::ClientError
          status = 499
          raise ex
        rescue ex
          STDERR.puts({
            event:      "request_failed",
            error:      ex.class.name,
            request_id: request_id(context),
          }.to_json)
          status = error(context, 500, "internal", "internal server error")
        ensure
          if runtime_snapshot.request_logging?
            STDERR.puts({
              event: "request", request_id: request_id(context), method: context.request.method,
              path: context.request.path, status: status,
              duration_ms: (Time.instant - started).total_milliseconds.round.to_i,
            }.to_json)
          end
        end
      end
    end

    def close : Nil
      database.close
    end

    private def route(context : HTTP::Server::Context) : Int32
      request = context.request
      path = request.path
      if path.starts_with?("/v1/")
        return incompatible_protocol(context) unless compatible_protocol?(request)
      end
      case {request.method, path}
      when {"GET", "/healthz"}, {"HEAD", "/healthz"}
        json(context, 200, %({"status":"ok"}))
      when {"GET", "/readyz"}, {"HEAD", "/readyz"}
        database.db.scalar("SELECT 1")
        json(context, 200, %({"status":"ready"}))
      when {"GET", "/metrics"}, {"HEAD", "/metrics"}
        context.response.headers["Cache-Control"] = "no-store"
        write_body(
          context, 200, "text/plain; version=0.0.4; charset=utf-8",
          metrics.render(store, handoffs)
        )
      when {"POST", "/v1/join"}
        claim_ship(context)
      when {"POST", "/v1/ships/inspect"}
        json(context, 200, store.inspect_ship(parse_body(context, ShipInspection)))
      when {"POST", "/v1/transmissions"}
        accept_transmission(context)
      when {"POST", "/v1/transmissions/withdraw"}
        withdraw_transmission(context)
      when {"POST", "/v1/hails"}
        accept_hail(context)
      when {"POST", "/v1/radio/wait"}
        radio_wait(context)
      when {"POST", "/v1/transmissions/ack"}
        acknowledge_transmission(context)
      when {"POST", "/v1/hails/ack"}
        store.acknowledge_hail(parse_body(context, HailAck))
        metrics.hail("collected")
        json(context, 200, %({"state":"acknowledged"}))
      when {"POST", "/v1/relationships/close"}
        closure = parse_body(context, RelationshipClose)
        store.close_relationship(
          closure,
          exempt_from_rotation_limit: runtime_snapshot.rate_limit_excluded?(
            closure.auth.ship
          )
        )
        handoffs.notify(closure.auth.ship)
        closure.retained_ships.each { |ship| handoffs.notify(ship) }
        json(context, 200, %({"state":"retuning"}))
      when {"POST", "/v1/relationships/retune/ack"}
        store.acknowledge_retune(parse_body(context, RetuneAck))
        json(context, 200, %({"state":"acknowledged"}))
      when {"POST", "/v1/relationships/allow"}
        store.allow_relationship(parse_body(context, RelationshipAllow))
        metrics.hail("allowed")
        json(context, 200, %({"state":"active"}))
      when {"POST", "/v1/owners/rotate"}
        rotation = parse_body(context, OwnerRotation)
        store.rotate_owner(
          rotation,
          exempt_from_rotation_limit: runtime_snapshot.rate_limit_excluded?(
            rotation.auth.ship
          )
        )
        json(context, 200, %({"state":"rotated"}))
      when {"POST", "/v1/ships/change"}
        store.ship_change(parse_body(context, ShipChange))
        json(context, 200, %({"state":"updated"}))
      else
        error(context, 404, "not_found", "API route not found")
      end
    end

    private def acknowledge_transmission(context : HTTP::Server::Context) : Int32
      acknowledgement = parse_body(context, TransmissionAck)
      latency = if prepared = handoffs.prepared_for_ack(
                     acknowledgement.transmission_id, acknowledgement.auth.ship
                   )
                  store.verify_ack(acknowledgement)
                  handoffs.complete(acknowledgement.transmission_id)
                  Math.max(Time.utc.to_unix - prepared.accepted_at, 0_i64)
                else
                  store.acknowledge(acknowledgement)
                end
      metrics.transmission("acknowledged")
      latency.try { |seconds| metrics.acknowledgement_latency(seconds) }
      json(context, 200, %({"state":"acknowledged"}))
    end

    private def claim_ship(context : HTTP::Server::Context) : Int32
      counted = false
      policy_outcome = nil.as(String?)
      snapshot = runtime_snapshot
      peer = context.request.remote_address
      headers = context.request.headers
      source = snapshot.registration_source(
        peer, headers
      )
      source_bucket = source[:bucket]
      unless source_bucket
        outcome = source[:cidr_denied] ? "cidr_denied" : "invalid"
        metrics.registration(outcome)
        counted = true
        return error(
          context, 403, "registration_forbidden",
          "registration is not available from this source"
        )
      end
      prepared = store.prepare_claim(parse_body(context, ShipClaim))
      store.claim(
        prepared, source_bucket, snapshot.registration_allowances,
        policy_current: -> do
          current = runtime_snapshot
          if current.same?(snapshot)
            true
          else
            current_source = current.registration_source(peer, headers)
            policy_outcome = if current_source[:cidr_denied]
                               "cidr_denied"
                             elsif current.registration_allowances.closed?
                               "closed"
                             else
                               "policy_changed"
                             end
            false
          end
        end
      )
      metrics.registration("accepted")
      counted = true
      json(context, 201, %({"state":"claimed"}))
    rescue ex : RegistrationUnavailable
      unless counted
        if snapshot.try { |value| value.registration_allowances.closed? }
          policy_outcome ||= "closed"
        end
        if outcome = policy_outcome
          metrics.registration(outcome)
          counted = true
        end
      end
      error(
        context, 403, "registration_forbidden",
        "registration is not available from this source"
      )
    rescue ex : RegistrationLimited
      metrics.registration("rate_limited") unless counted
      counted = true
      context.response.headers["Retry-After"] = ex.retry_after_seconds.to_s
      error(
        context, 429, "registration_limited",
        "relay is receiving too many registrations"
      )
    rescue ex : Conflict
      metrics.registration("conflict") unless counted
      raise ex
    rescue ex : Unavailable
      metrics.registration("capacity") unless counted
      raise ex
    rescue ex : JSON::ParseException | JSON::SerializableError | Invalid | Unauthorized
      metrics.registration("invalid") unless counted
      raise ex
    end

    private def accept_transmission(context : HTTP::Server::Context) : Int32
      acceptance_at = Time.instant + ACCEPTANCE_TARGET
      outcome = "rejected"
      counted = false
      envelope = parse_body(context, SignedRelayEnvelope)
      prepared = store.prepare(envelope)
      charge_transmission!(context, envelope.sender_ship, prepared.ciphertext.size)
      unless prepared.stored?
        if store.deliverable?(prepared)
          remaining = acceptance_at - Time.instant
          if remaining > Time::Span.zero && handoffs.deliver(prepared, remaining)
            outcome = "direct"
          elsif store.persist(prepared)
            handoffs.notify(envelope.recipient_ship)
            outcome = "queued"
          end
        end
      end
      wait_for_acceptance(acceptance_at)
      metrics.transmission(outcome)
      if outcome != "rejected"
        metrics.transmission_bytes(outcome, prepared.ciphertext.size.to_i64)
      end
      counted = true
      json(context, 202, %({"state":"accepted"}))
    rescue ex
      metrics.transmission("rejected") unless counted
      raise ex
    end

    private def withdraw_transmission(context : HTTP::Server::Context) : Int32
      acceptance_at = Time.instant + ACCEPTANCE_TARGET
      body = read_request_body(context)
      withdrawal = TransmissionWithdrawal.from_json(body)
      store.verify_withdrawal(withdrawal)
      metrics.withdrawal("requested")

      charge_transmission!(context, withdrawal.auth.ship, body.bytesize)

      changed = store.withdraw(withdrawal)
      metrics.withdrawal("changed") if changed
      wait_for_acceptance(acceptance_at)
      json(context, 202, %({"state":"accepted"}))
    end

    private def accept_hail(context : HTTP::Server::Context) : Int32
      acceptance_at = Time.instant + ACCEPTANCE_TARGET
      outcome = "rejected"
      counted = false
      hail = parse_body(context, Hail)
      if prepared = store.prepare_hail(hail)
        excluded = runtime_snapshot.rate_limit_excluded?(hail.sender_ship)
        if (excluded || hail_window.allow?(hail.sender_ship)) &&
           store.persist_hail(prepared)
          handoffs.notify(hail.recipient_ship)
          outcome = "accepted"
        end
      end
      wait_for_acceptance(acceptance_at)
      metrics.hail(outcome)
      counted = true
      json(context, 202, %({"state":"accepted"}))
    rescue ex
      metrics.hail("rejected") unless counted
      raise ex
    end

    private def radio_wait(context : HTTP::Server::Context) : Int32
      request = parse_body(context, RadioWaitRequest)
      streamed = false
      response = wait(request) do
        unless streamed
          context.response.status_code = 200
          context.response.content_type = "application/json; charset=utf-8"
          context.response.headers["Cache-Control"] = "no-store"
          streamed = true
        end
        context.response.print(' ')
        context.response.flush
      end
      outcome = if response.envelope
                  "transmission"
                elsif response.hail
                  "hail"
                elsif !response.contact_updates.empty?
                  "contact_update"
                else
                  "timeout"
                end
      status = if streamed
                 context.response.print(response.to_json)
                 200
               else
                 json(context, 200, response.to_json)
               end
      metrics.radio_wait(outcome)
      status
    rescue ex : IO::Error | HTTP::Server::ClientError
      metrics.radio_wait("disconnect")
      raise ex
    rescue ex
      metrics.radio_wait("error")
      raise ex
    end

    private def compatible_protocol?(request : HTTP::Request) : Bool
      request.headers["X-Tinrelay-Protocol"]?.try(&.to_i?) == PROTOCOL
    end

    private def incompatible_protocol(context : HTTP::Server::Context) : Int32
      supplied = context.request.headers["X-Tinrelay-Protocol"]?.try(&.to_i?) || 0
      relation = supplied < PROTOCOL ? "older" : "newer"
      json(context, 426, {
        error: "protocol_incompatible", client_protocol: supplied,
        supported_min: PROTOCOL, supported_max: PROTOCOL, relation: relation,
      }.to_json)
    end

    private def wait(request : RadioWaitRequest, &) : RadioWaitResponse
      deadline = Time.instant + request.hold_seconds.seconds
      response = store.wait_once(request)
      return response unless response.empty? && request.hold_seconds > 0

      waiter = handoffs.park(request.auth.ship, request.auth.radio_generation)
      begin
        loop do
          # A second read after parking closes the race between the first read
          # and waiter registration without periodically polling SQLite.
          response = store.wait_once(request)
          return response unless response.empty?
          remaining = deadline - Time.instant
          return response if remaining <= Time::Span.zero
          wait_for = Math.min(remaining, @radio_wait_heartbeat_interval)
          case event = handoffs.wait(waiter, wait_for)
          when SignedRelayEnvelope
            envelope = event
            return RadioWaitResponse.new(envelope: envelope)
          when :timeout
            return response if Time.instant >= deadline
            yield
          end
        end
      ensure
        handoffs.release(request.auth.ship, waiter)
      end
    end

    private def parse_body(context, type : T.class) : T forall T
      type.from_json(read_request_body(context))
    end

    private def read_request_body(context : HTTP::Server::Context) : String
      content_length = context.request.headers["Content-Length"]?.try(&.to_i64?)
      if content_length && content_length > MAX_REQUEST_BYTES
        raise Invalid.new("request body exceeds #{MAX_REQUEST_BYTES} bytes")
      end
      read_limited(context.request.body)
    end

    private def charge_transmission!(context : HTTP::Server::Context,
                                     ship : String, bytes : Int32) : Nil
      snapshot = runtime_snapshot
      return if snapshot.rate_limit_excluded?(ship)
      source = snapshot.source_bucket(
        context.request.remote_address, context.request.headers
      )
      if retry_after = transmission_buckets.admit(source, bytes)
        raise TransmissionLimited.new(retry_after.to_i64)
      end
    end

    private def wait_for_acceptance(acceptance_at : Time::Instant) : Nil
      remaining = acceptance_at - Time.instant
      sleep remaining if remaining > Time::Span.zero
    end

    private def read_limited(input : IO?) : String
      return "" unless input
      BoundedIO.read(input, MAX_REQUEST_BYTES) ||
        raise Invalid.new("request body exceeds #{MAX_REQUEST_BYTES} bytes")
    end

    private def write_body(context : HTTP::Server::Context, status : Int32,
                           content_type : String, body : String) : Int32
      context.response.status_code = status
      context.response.content_type = content_type
      context.response.content_length = body.bytesize
      context.response.print(body) unless context.request.method == "HEAD"
      status
    end

    private def json(context, status : Int32, body : String) : Int32
      context.response.headers["Cache-Control"] = "no-store"
      write_body(context, status, "application/json; charset=utf-8", body)
    end

    private def error(context, status : Int32, code : String, message : String) : Int32
      json(context, status, {error: code, message: message}.to_json)
    end

    private def request_id(context) : String
      context.request.headers["X-Request-ID"]? || "local-#{Process.pid}"
    end

    private def load_runtime_snapshot(allow_missing_default : Bool) : RuntimeSnapshot
      candidate = TinrelaydConfig.load(
        config.configuration_path, allow_missing_default
      )
      RuntimeSnapshot.new(
        candidate.try(&.registration_allowances) || RegistrationAllowances.new,
        candidate.try(&.registration_deny_cidrs) || [] of IPNetwork,
        candidate.try(&.client_address_policy) ||
        ClientAddressPolicy.new("direct", [] of String),
        candidate.try(&.rate_limit_exclusions) || [] of String,
        candidate.try(&.logging.requests) != false
      )
    end
  end
end
