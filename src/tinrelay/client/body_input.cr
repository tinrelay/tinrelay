require "../error"
require "../bounded_io"

module Tinrelay
  module BodyInput
    MAX_BYTES = 16 * 1024

    def self.read(stdin : IO = STDIN) : String
      BoundedIO.read(stdin, MAX_BYTES) ||
        raise Invalid.new("transmission body exceeds #{MAX_BYTES} UTF-8 bytes")
    rescue ex : IO::Error
      raise Invalid.new("transmission body cannot be read")
    end
  end
end
