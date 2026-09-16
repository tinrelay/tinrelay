require "random/secure"

module Tinrelay
  module AtomicPrivateFile
    def self.write(path : String, contents : String) : Nil
      directory = File.dirname(path)
      unless Dir.exists?(directory)
        Dir.mkdir_p(directory, mode: 0o700)
      end
      PrivateStorage.secure(directory, 0o700)
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
