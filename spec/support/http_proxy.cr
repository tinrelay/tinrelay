require "../spec_helper"

module TinrelayProxySpec
  TLS_ROOT = File.join(__DIR__, "proxy_tls")

  # These are public, test-only TLS fixtures, unrelated to any ship or service key.
  class Proxy
    getter requests = [] of HTTP::Request
    property next_action : Symbol = :forward
    @listener : TCPServer
    @sockets = [] of TCPSocket

    def initialize(@origin : URI)
      @listener = TCPServer.new("127.0.0.1", 0)
      spawn do
        while socket = @listener.accept?
          @sockets << socket
          spawn { serve(socket) }
        end
      end
    end

    def url : String
      "http://fixture-user:fixture-secret@127.0.0.1:#{@listener.local_address.port}"
    end

    def close : Nil
      @listener.close
      @sockets.each(&.close)
    end

    private def serve(socket : TCPSocket) : Nil
      socket.read_timeout = 3.seconds
      request = HTTP::Request.from_io(socket).as(HTTP::Request)
      requests << request
      action = next_action
      self.next_action = :forward
      return if action == :drop
      if action == :refuse
        socket << "HTTP/1.1 407 Authentication required\r\n" +
                  "X-Private: fixture-secret\r\nContent-Length: 0\r\n\r\n"
        socket.flush
        return
      end
      sleep 80.milliseconds if action == :slow
      upstream = TCPSocket.new("127.0.0.1", @origin.port.not_nil!)
      @sockets << upstream
      socket << "HTTP/1.1 200 Connection established\r\n\r\n"
      socket.flush
      finished = Channel(Nil).new(1)
      spawn do
        begin
          IO.copy(socket, upstream)
        rescue IO::Error
        ensure
          upstream.close
          finished.send(nil)
        end
      end
      begin
        IO.copy(upstream, socket)
      ensure
        socket.close
        upstream.close
        TinrelaySpec.receive(finished)
      end
    rescue IO::Error | TypeCastError
    ensure
      socket.close
    end
  end

  def self.with_relay(&)
    previous = ENV["SSL_CERT_FILE"]?
    ENV["SSL_CERT_FILE"] = File.join(TLS_ROOT, "fixture.crt")
    TinrelaySpec.with_server do |root, direct, api|
      bodies = [] of String
      headers = [] of HTTP::Headers
      lose_response = Channel(Nil).new(1)
      health_failure = Channel(Symbol).new(1)
      context = OpenSSL::SSL::Context::Server.new
      context.certificate_chain = File.join(TLS_ROOT, "fixture.crt")
      context.private_key = File.join(TLS_ROOT, "fixture.key")
      tls = HTTP::Server.new do |http|
        body = http.request.body.try(&.gets_to_end)
        headers << http.request.headers.dup
        if http.request.path == "/healthz"
          failure = select
          when value = health_failure.receive then value
          else
            :none
          end
          if failure == :eof
            http.response.headers["Connection"] = "close"
            http.response.output = IO::Memory.new
            next
          elsif failure == :malformed
            http.response.version = "PRIVATE-WIRE-MARKER"
          end
        end
        bodies << body.not_nil! if http.request.path == "/v1/transmissions"
        response = HTTP::Client.exec(http.request.method,
          "#{direct}#{http.request.resource}", headers: http.request.headers, body: body)
        http.response.status_code = response.status_code
        http.response.headers["Connection"] = "close"
        lost = if http.request.path == "/v1/transmissions"
                 select
                 when lose_response.receive then true
                 else
                   false
                 end
               else
                 false
               end
        # Accept at the real API, then cut the advertised body short on the wire.
        http.response.content_length = response.body.bytesize
        http.response.print(lost ? response.body.byte_slice(0, 1) : response.body)
      end
      address = tls.bind_tls("127.0.0.1", 0, context)
      spawn { tls.listen }
      origin = "https://relay.invalid:#{address.port}"
      proxy = Proxy.new(URI.parse(origin))
      yield root, origin, proxy, api, bodies, headers, lose_response, health_failure
    ensure
      proxy.try(&.close)
      tls.try(&.close)
    end
  ensure
    ENV["SSL_CERT_FILE"] = previous
  end
end
