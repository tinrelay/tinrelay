require "./platform/private_storage"

module Tinrelay
  module PrivateInput
    def self.read(path : String, label : String, stdin : IO = STDIN) : String
      value = if path == "-"
                stdin.gets_to_end
              else
                raise NotFound.new("#{label} file not found") unless File.file?(path)
                unless PrivateStorage.private?(path)
                  raise Invalid.new("#{label} file must be private to the current user")
                end
                File.read(path)
              end
      value = value.chomp
      raise Invalid.new("#{label} is empty") if value.empty?
      value
    end
  end
end
