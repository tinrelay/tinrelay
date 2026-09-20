module Tinrelay
  module ServerRuntime
    def self.thread_count(value : String?) : Int32
      return System.cpu_count unless value
      count = value.to_i?
      unless count && count.in?(1..System.cpu_count)
        raise Invalid.new("--threads must be between 1 and #{System.cpu_count}")
      end
      count
    end

    def self.enable_multicore(count : Int32) : Nil
      Fiber::ExecutionContext.default.resize(count)
    end
  end
end
