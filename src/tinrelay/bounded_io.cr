module Tinrelay
  module BoundedIO
    def self.read(input : IO, limit : Int32 | Int64) : String?
      buffer = IO::Memory.new
      count = IO.copy(input, buffer, limit.to_i64 + 1)
      return if count > limit
      buffer.to_s
    end
  end
end
