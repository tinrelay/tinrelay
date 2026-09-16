module Tinrelay
  module PrivateStorage
    def self.secure(path : String, permissions : Int) : Nil
      File.chmod(path, permissions)
    end

    def self.private?(path : String) : Bool
      File.info(path).permissions.value & 0o077 == 0
    end

    def self.replace(source : String, destination : String) : Nil
      File.rename(source, destination)
      [File.dirname(source), File.dirname(destination)].uniq.each do |directory|
        File.open(directory, "r", &.fsync)
      end
    end

    # Every caller can safely replay a lingering record after a crash.
    def self.delete_replay_safe(path : String) : Nil
      File.delete(path)
      File.open(File.dirname(path), "r", &.fsync)
    end
  end
end
