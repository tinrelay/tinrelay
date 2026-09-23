module Tinrelay
  module CLIArguments
    private def extract(argv : Array(String), name : String) : String?
      index = argv.index(name)
      return nil unless index
      raise Invalid.new("#{name} requires a value") unless index + 1 < argv.size
      argv.delete_at(index)
      argv.delete_at(index)
    end

    private def required(argv : Array(String), name : String) : String
      extract(argv, name) || raise Invalid.new("#{name} is required")
    end

    private def no_extra!(argv : Array(String)) : Nil
      raise Invalid.new("unexpected arguments: #{argv.join(' ')}") unless argv.empty?
    end
  end
end
