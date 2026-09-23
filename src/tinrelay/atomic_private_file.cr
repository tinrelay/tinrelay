require "random/secure"

module Tinrelay
  module AtomicPrivateFile
    def self.write(path : String, contents : String) : Nil
      directory = File.dirname(path)
      PrivateStorage.prepare_directory(directory)
      temporary = "#{path}.tmp.#{Process.pid}.#{Random::Secure.hex(6)}"
      begin
        File.open(temporary, "w", perm: 0o600) do |file|
          file << contents
          file.flush
          file.fsync
        end
        PrivateStorage.secure(temporary, 0o600)
        PrivateStorage.replace(temporary, path)
      ensure
        File.delete(temporary) if File.exists?(temporary)
      end
    end
  end
end
