require "../error"

module Tinrelay
  module BodyInput
    MAX_BYTES = 16 * 1024

    def self.read(stdin : IO = STDIN) : String
      buffer = IO::Memory.new
      count = IO.copy(stdin, buffer, MAX_BYTES + 1)
      if count > MAX_BYTES
        raise Invalid.new("transmission body exceeds #{MAX_BYTES} UTF-8 bytes")
      end
      buffer.to_s
    rescue ex : IO::Error
      raise Invalid.new("transmission body cannot be read")
    end
  end
end
