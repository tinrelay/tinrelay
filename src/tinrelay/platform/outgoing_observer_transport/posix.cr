require "socket"

module Tinrelay
  module OutgoingObserverTransport
    def self.valid_endpoint?(path : String) : Bool
      return false unless Path.new(path).absolute?
      info = File.info(File.dirname(path))
      info.directory? && info.permissions.value & 0o077 == 0
    end

    def self.notify(path : String, encoded : String, timeout : Time::Span) : Nil
      socket = Socket.unix
      begin
        socket.connect(Socket::UNIXAddress.new(path), timeout)
        socket.write_timeout = timeout
        socket.puts(encoded)
      ensure
        socket.close
      end
    end
  end
end
