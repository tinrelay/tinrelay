require "http/client"

module Tinrelay
  # Notification only: queue state is the retry authority, never a callback receipt.
  class MailHints
    INTERVAL = 60.seconds
    TIMEOUT  = 10.seconds

    def initialize(@store : Store, @timeout = TIMEOUT, @log : IO = STDERR)
    end

    def notify(destinations : Array(MailHintDestination),
               policy_current : Proc(Bool) = -> { true }) : Nil
      destinations.each do |destination|
        next unless @store.pending_mail?(destination.ship)
        # A completed callback does not authorize the next request under a replaced policy.
        break unless policy_current.call
        begin
          status = deliver(destination)
          outcome = case status
                    when 200..299 then "accepted"
                    when 401, 403 then "authentication_failed"
                    else               "not_accepted"
                    end
          @log.puts({event: "mail_hint", local_ship: destination.ship,
                     outcome: outcome, http_status: status}.to_json)
        rescue ex
          # No exception text: TLS/parser/transport errors may contain endpoint or wire data.
          @log.puts({event: "mail_hint", local_ship: destination.ship,
                     outcome: "transport_failed"}.to_json)
        end
      end
    end

    private def deliver(destination : MailHintDestination) : Int32
      uri = URI.parse(destination.url)
      host = uri.host.not_nil!
      port = uri.port || 443
      socket = TCPSocket.new(host, port, dns_timeout: @timeout, connect_timeout: @timeout)
      socket.read_timeout = @timeout
      socket.write_timeout = @timeout
      finished = Channel(Nil).new(1)
      spawn do
        select
        when finished.receive
        when timeout(@timeout)
          socket.close
        end
      end
      # Standard peer verification and hostname/SNI; no proxy or custom trust mode.
      tls = OpenSSL::SSL::Socket::Client.new(socket,
        context: OpenSSL::SSL::Context::Client.new, hostname: host, sync_close: true)
      client = HTTP::Client.new(tls, host, port)
      headers = HTTP::Headers{"Content-Type" => "application/json", "Connection" => "close"}
      headers[destination.auth_header] = destination.auth_value
      body = {contract: "tinrelay-mail-hint-v1", local_ship: destination.ship}.to_json
      client.exec("POST", "/hint", headers: headers, body: body) do |response|
        # Only status is relevant. Never read, log, or act on a response body/redirect.
        status = response.status_code
        client.close
        status
      end
    ensure
      finished.try(&.send(nil))
      socket.try(&.close)
    end
  end
end
