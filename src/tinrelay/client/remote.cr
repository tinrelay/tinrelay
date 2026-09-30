module Tinrelay
  class Remote
    # Ordinary responses fit the largest transmission plus its JSON wrapper.
    # Identity responses are separately bounded from protocol 1's maximum accepted
    # permanent-history allowance.
    MAX_RESPONSE_BYTES      = MAX_ORDINARY_RESPONSE_BYTES.to_i
    IDENTITY_RESPONSE_PATHS = {"/v1/ships/inspect", "/v1/radio/wait"}
    ROTATION_LIMIT_PATHS    = {"/v1/owners/rotate", "/v1/relationships/close"}

    getter origin : String
    @proxy : HTTPProxy?

    def initialize(@origin, http_proxy : String? = nil)
      Origin.validate!(origin)
      selected = http_proxy || (URI.parse(origin).scheme == "https" ? ENV["HTTPS_PROXY"]? : nil)
      @proxy = HTTPProxy.new(selected) if selected && !selected.empty?
    end

    def proxied? : Bool
      !@proxy.nil?
    end

    def diagnose
      started = Time.instant
      document = JSON.parse(request("GET", "/healthz")).as_h?
      unless document && document["status"]?.try(&.as_s?) == "ok"
        raise Error.new("relay health response is invalid")
      end
      {state: "ok", transport: proxied? ? "http_proxy" : "direct",
       elapsed_ms: (Time.instant - started).total_milliseconds.round.to_i64}
    rescue JSON::ParseException
      raise Error.new("relay health response is invalid")
    rescue error : OpenSSL::Error
      raise Error.new("relay health TLS failed")
    rescue error : IO::Error
      raise Error.new("relay health HTTP failed")
    end

    def post(path : String, body : String) : String
      request("POST", path, body)
    end

    private def request(method : String, path : String,
                        body : String? = nil) : String
      uri = URI.parse("#{origin.rstrip('/')}#{path}")
      client = if proxy = @proxy
                 proxy.open(uri, read_timeout(path))
               else
                 HTTP::Client.new(uri)
               end
      client.connect_timeout = 5.seconds
      client.read_timeout = read_timeout(path)
      headers = HTTP::Headers{
        "Accept"              => "application/json",
        "User-Agent"          => "tinrelay/#{VERSION}",
        "X-Request-ID"        => Ids.uuid,
        "X-Tinrelay-Protocol" => PROTOCOL.to_s,
      }
      headers["Content-Type"] = "application/json" if body
      if @proxy
        host = uri.host.not_nil!
        headers["Host"] = uri.port && uri.port != 443 ? "#{host}:#{uri.port}" : host
      end
      wire_response = begin
        client.exec(method, uri.request_target, headers: headers, body: body) do |response|
          {response.status_code, response.success?,
           read_body(response.body_io, response_limit(path)), response.headers}
        end
      rescue error : IO::Error | OpenSSL::Error | Error
        raise error
      rescue error
        # Crystal's HTTP parser also raises plain Exception with wire text.
        raise ProxyFailure.new("http", "invalid_response", false) if @proxy
        raise error
      end
      response_body(*wire_response, path)
    rescue error : Socket::Error | IO::TimeoutError
      raise ProxyFailure.new("http", "transport_unavailable", true) if @proxy
      raise TransportUnavailable.new
    rescue error : IO::Error
      if @proxy
        retryable = retryable_transport_error?(error) || error.is_a?(IO::EOFError) ||
                    error.os_error.in?(Errno::ECONNRESET, WinError::WSAECONNRESET,
                      WinError::WSAECONNABORTED)
        reason = retryable ? "transport_unavailable" : "invalid_response"
        raise ProxyFailure.new("http", reason, retryable)
      end
      raise TransportUnavailable.new if retryable_transport_error?(error)
      raise error
    rescue error : OpenSSL::Error
      raise ProxyFailure.new("http", "tls_failure", false) if @proxy
      raise error
    ensure
      client.try(&.close)
    end

    private def retryable_transport_error?(error : IO::Error) : Bool
      case os_error = error.os_error
      when Errno
        os_error == Errno.parse?("ETIMEDOUT") || os_error == Errno.parse?("EPIPE")
      when WinError
        os_error == WinError.parse?("WSAETIMEDOUT")
      else
        false
      end
    end

    private def read_timeout(path : String) : Time::Span
      return 115.seconds if path == "/v1/radio/wait"
      35.seconds
    end

    private def response_limit(path : String) : Int64
      return MAX_IDENTITY_RESPONSE_BYTES if IDENTITY_RESPONSE_PATHS.includes?(path)
      MAX_RESPONSE_BYTES.to_i64
    end

    private def read_body(io : IO, limit : Int64) : String
      BoundedIO.read(io, limit) ||
        raise Error.new("relay response exceeds #{limit} bytes")
    end

    private def response_body(status_code : Int32, success : Bool,
                              body : String, headers : HTTP::Headers,
                              path : String) : String
      return body if success
      if status_code == 426
        evidence = protocol_mismatch_evidence(body)
        raise ProtocolMismatch.new(
          evidence.client_protocol, evidence.supported_min,
          evidence.supported_max, evidence.relation
        )
      end
      if status_code == 503
        valid, back_at = maintenance_evidence(body)
        raise Maintenance.new(back_at) if valid
      end
      if status_code == 429 && path == "/v1/join"
        retry_after = simple_limit_evidence(body, headers, "registration_limited")
        raise RegistrationLimited.new(retry_after) if retry_after
      end
      if status_code == 429 && path.in?({
           "/v1/transmissions", "/v1/transmissions/withdraw",
         })
        retry_after = simple_limit_evidence(body, headers, "transmission_limited")
        raise TransmissionLimited.new(retry_after) if retry_after
      end
      if status_code == 403 && path == "/v1/join" && registration_forbidden?(body)
        raise RegistrationUnavailable.new
      end
      if status_code == 429 && ROTATION_LIMIT_PATHS.includes?(path)
        retry_after = rotation_limit_evidence(body, headers)
        raise RotationLimited.new(retry_after) if retry_after
      end
      case status_code
      when 400      then raise Invalid.new("relay rejected an invalid request")
      when 401, 403 then raise Unauthorized.new("relay authentication failed")
      when 404      then raise NotFound.new("relay object is unavailable")
      when 409
        raise RadioWaitReconnect.new if path == "/v1/radio/wait"
        raise Conflict.new("relay reported a state conflict")
      when 410 then raise Expired.new("relay object has expired")
      when 429 then raise Unavailable.new("relay rate limit reached")
      when 503 then raise Unavailable.new("relay is unavailable")
      else          raise Error.new("relay returned HTTP #{status_code}")
      end
    end

    private def registration_forbidden?(body : String) : Bool
      object = JSON.parse(body).as_h?
      return false unless object
      object["error"]?.try(&.as_s?) == "registration_forbidden"
    rescue JSON::ParseException
      false
    end

    private def simple_limit_evidence(body : String, headers : HTTP::Headers,
                                      expected_error : String) : Int64?
      retry_after = headers["Retry-After"]?.try(&.to_i64?)
      return nil unless retry_after && retry_after > 0
      object = JSON.parse(body).as_h?
      return nil unless object
      return nil unless object["error"]?.try(&.as_s?) == expected_error
      retry_after
    rescue JSON::ParseException
      nil
    end

    private def rotation_limit_evidence(body : String,
                                        headers : HTTP::Headers) : Int64?
      header = headers["Retry-After"]?.try(&.to_i64?)
      return nil unless header && header > 0
      evidence = RotationLimitEvidence.from_json(body)
      return nil unless evidence.error == "rotation_limited"
      return nil unless evidence.retry_after_seconds == header
      header
    rescue JSON::ParseException | JSON::SerializableError
      nil
    end

    private def protocol_mismatch_evidence(body : String) : ProtocolMismatchEvidence
      evidence = ProtocolMismatchEvidence.from_json(body)
      relation = if evidence.client_protocol < evidence.supported_min
                   "older"
                 elsif evidence.client_protocol > evidence.supported_max
                   "newer"
                 else
                   "equal"
                 end
      unless evidence.error == "protocol_incompatible" &&
             evidence.supported_min <= evidence.supported_max &&
             evidence.relation == relation && relation != "equal"
        raise Error.new("relay returned invalid protocol-mismatch evidence")
      end
      evidence
    rescue JSON::ParseException | JSON::SerializableError
      raise Error.new("relay returned invalid protocol-mismatch evidence")
    end

    private def maintenance_evidence(body : String) : Tuple(Bool, Time?)
      evidence = MaintenanceEvidence.from_json(body)
      unless evidence.error == "maintenance" && evidence.back_at_present?
        return {false, nil}
      end
      back_at = evidence.back_at.try { |value| Time.parse_rfc3339(value) }
      {true, back_at}
    rescue JSON::ParseException | JSON::SerializableError | Time::Format::Error
      {false, nil}
    end
  end
end
