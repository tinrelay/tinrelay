require "http_proxy"

module Tinrelay
  class ProxyFailure < Error
    getter phase : String
    getter retryable : Bool
    getter status_code : Int32?

    def initialize(@phase, reason : String, @retryable, @status_code = nil)
      super("relay proxy #{phase}: #{reason}")
    end
  end

  # Invocation-local connection policy, never ship identity or saved configuration.
  class HTTPProxy
    HANDSHAKE_TIMEOUT = 45.seconds

    @proxy : HTTP::Proxy::Client

    def initialize(value : String)
      uri = begin
        URI.parse(value)
      rescue URI::Error | ArgumentError
        raise Invalid.new("HTTP proxy URL is invalid")
      end
      unless uri.scheme == "http" && (host = uri.host) && !host.empty? &&
             uri.path.in?({"", "/"}) && !uri.query && !uri.fragment &&
             (uri.port || 80).in?(1..65535) && !value.each_byte.any? { |b| b <= 32 || b == 127 }
        raise Invalid.new("HTTP proxy must be an http:// URL with no path, query, or fragment")
      end
      user, password = begin
        username = uri.user.try { |part| URI.decode(part) }
        {username, username ? URI.decode(uri.password || "") : nil}
      rescue ArgumentError
        raise Invalid.new("HTTP proxy credentials are invalid")
      end
      if user.try(&.includes?(':'))
        raise Invalid.new("HTTP proxy username must not contain a colon")
      end
      hostname = uri.host.not_nil!
      if hostname.starts_with?('[') && hostname.ends_with?(']')
        hostname = hostname[1..-2]
      end
      @proxy = HTTP::Proxy::Client.new(hostname, uri.port || 80,
        username: user, password: password, user_agent: "tinrelay/#{VERSION}")
    end

    def open(uri : URI, response_timeout : Time::Span) : HTTP::Client
      unless uri.scheme == "https"
        raise Invalid.new("HTTP proxy tunnels require an https relay origin")
      end
      host = uri.host.not_nil!
      port = uri.port || 443
      io = @proxy.open(host, port, OpenSSL::SSL::Context::Client.new,
        dns_timeout: 5.seconds, connect_timeout: 5.seconds,
        read_timeout: HANDSHAKE_TIMEOUT, write_timeout: HANDSHAKE_TIMEOUT,
        handshake_timeout: HANDSHAKE_TIMEOUT)
      tls = io.as(OpenSSL::SSL::Socket::Client)
      tls.read_timeout = response_timeout
      tls.write_timeout = 35.seconds
      HTTP::Client.new(io, host, port)
    rescue error : HTTP::Proxy::Error
      raise ProxyFailure.new(error.phase.to_s, error.reason.to_s,
        error.retryable?, error.status_code)
    end
  end
end
