module Tinrelay
  class Error < Exception
  end

  class Invalid < Error
  end

  class Unauthorized < Error
  end

  class Conflict < Error
  end

  class RadioWaitReconnect < Conflict
    def initialize
      super("relay radio wait must reconnect")
    end
  end

  class Unavailable < Error
  end

  class RegistrationLimited < Unavailable
    getter retry_after_seconds : Int64

    def initialize(@retry_after_seconds)
      super(
        "relay is receiving too many registrations; " +
        "try again in #{retry_after_seconds} seconds"
      )
    end
  end

  class RegistrationUnavailable < Unavailable
    def initialize
      super("relay registration policy does not allow this claim")
    end
  end

  class TransmissionLimited < Unavailable
    getter retry_after_seconds : Int64
    getter transmission_id : String?
    getter sender_ship : String?

    def initialize(@retry_after_seconds, @transmission_id = nil, @sender_ship = nil)
      retry_command = if transmission_id && sender_ship
                        "; exact encrypted envelope retained; retry with: " +
                          "tinrelay --ship #{sender_ship} outbox retry #{transmission_id}"
                      else
                        ""
                      end
      super(
        "relay transmission limit reached; try again in " +
        "#{retry_after_seconds} seconds#{retry_command}"
      )
    end
  end

  class RotationLimited < Unavailable
    getter retry_after_seconds : Int64

    def initialize(@retry_after_seconds)
      super(
        "relay rotation limit reached; try again in " +
        "#{retry_after_seconds} seconds"
      )
    end
  end

  # A failure at the relay's network boundary. Its distinct type lets a caller
  # retry narrowly without treating local I/O or unknown failures as transient.
  class TransportUnavailable < Unavailable
    def initialize
      super("relay transport is unavailable")
    end
  end

  class Maintenance < Unavailable
    getter back_at : Time?

    def initialize(@back_at = nil)
      suffix = back_at.try { |time| "; expected return #{time.to_rfc3339}" } || ""
      super("relay is temporarily unavailable for maintenance#{suffix}")
    end
  end

  class NotFound < Error
  end

  class Expired < Error
  end

  class AcceptanceUnknown < Error
    getter transmission_id : String
    getter sender_ship : String

    def initialize(@transmission_id, @sender_ship, detail : String? = nil)
      suffix = detail ? ": #{detail}" : ""
      super(
        "relay acceptance is unknown for transmission #{transmission_id}; " +
        "exact encrypted envelope retained; retry with: " +
        "tinrelay --ship #{sender_ship} outbox retry #{transmission_id}#{suffix}"
      )
    end
  end

  class HailAcceptanceUnknown < Error
    getter sender_ship : String
    getter recipient_ship : String

    def initialize(@sender_ship, @recipient_ship, detail : String? = nil)
      suffix = detail ? ": #{detail}" : ""
      super(
        "relay acceptance is unknown for hail#{suffix}; run again with: " +
        "tinrelay --ship #{sender_ship} hail #{recipient_ship}"
      )
    end
  end

  class ProtocolMismatch < Error
    getter client_protocol : Int32
    getter supported_min : Int32
    getter supported_max : Int32
    getter relation : String

    def initialize(@client_protocol, @supported_min, @supported_max, @relation)
      super(
        "client protocol #{client_protocol} is #{relation} than supported range " +
        "#{supported_min}..#{supported_max}"
      )
    end
  end
end
