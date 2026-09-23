require "./error"

module Tinrelay
  module Names
    SHIP  = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
    LABEL = SHIP

    def self.ship!(value : String) : String
      raise Invalid.new("invalid ship name") unless SHIP.matches?(value)
      value
    end

    def self.label!(value : String) : String
      raise Invalid.new("invalid local attention label") unless LABEL.matches?(value)
      value
    end

    def self.attention!(value : String) : String
      return value if value.empty?
      label!(value)
    end

    def self.coordinate!(value : String) : Tuple(String, String)
      parts = value.split('@')
      raise Invalid.new("coordinate must be local-label@ship") unless parts.size == 2
      {attention!(parts[0]), ship!(parts[1])}
    end
  end
end
