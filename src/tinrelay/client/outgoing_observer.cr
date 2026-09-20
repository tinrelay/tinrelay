require "json"

require "../platform/outgoing_observer_transport"

module Tinrelay
  class OutgoingObserver
    CONTRACT         = "tinrelay-outgoing-observer-v1"
    MAX_CONFIG_BYTES = 4 * 1024
    MAX_EVENT_BYTES  = 20 * 1024
    TIMEOUT          = 50.milliseconds

    struct Config
      include JSON::Serializable

      getter socket_path : String

      def initialize(@socket_path)
      end
    end

    struct Event
      include JSON::Serializable

      getter contract : String
      getter kind : String
      getter transmission_id : String
      getter sender_ship : String
      getter recipient_ship : String
      getter attention_label : String
      getter author_label : String?
      getter body : String

      def initialize(transmission : SignedTransmission)
        @contract = CONTRACT
        @kind = "transmission"
        @transmission_id = transmission.transmission_id
        @sender_ship = transmission.sender_ship
        @recipient_ship = transmission.recipient_ship
        @attention_label = transmission.to_label
        @author_label = transmission.from_label
        @body = transmission.body
      end
    end

    def self.from_config(path : String) : self?
      return unless File.file?(path)
      config = Config.from_json(read_config(path))
      socket_path = config.socket_path
      return unless OutgoingObserverTransport.valid_endpoint?(socket_path)
      new(socket_path)
    rescue
      nil
    end

    private def self.read_config(path : String) : String
      File.open(path) do |file|
        buffer = IO::Memory.new
        count = IO.copy(file, buffer, MAX_CONFIG_BYTES + 1)
        raise ArgumentError.new("observer config exceeds limit") if count > MAX_CONFIG_BYTES
        buffer.to_s
      end
    end

    def initialize(@socket_path : String)
    end

    def notify(transmission : SignedTransmission) : Nil
      encoded = Event.new(transmission).to_json
      return if encoded.bytesize > MAX_EVENT_BYTES

      OutgoingObserverTransport.notify(@socket_path, encoded, TIMEOUT)
    rescue
      # This is an optional same-user presentation hook. A failed observer must
      # never change the accepted send, its evidence, or its outbox state.
    end
  end
end
