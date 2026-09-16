require "c/winbase"
require "crystal/system/windows"

require "../windows_private_file"

module Tinrelay
  module PrivateStorage
    REPLACE_FLAGS = LibC::MOVEFILE_REPLACE_EXISTING | LibC::MOVEFILE_WRITE_THROUGH

    def self.secure(path : String, _permissions : Int) : Nil
      WindowsPrivateFile.secure(path)
    end

    def self.private?(path : String) : Bool
      WindowsPrivateFile.private?(path)
    end

    def self.replace(source : String, destination : String) : Nil
      unless LibC.MoveFileExW(
               Crystal::System.to_wstr(source),
               Crystal::System.to_wstr(destination),
               REPLACE_FLAGS
             ) != 0
        raise File::Error.from_winerror(
          "Error replacing private file", file: source, other: destination
        )
      end
    end

    # Windows has no directory-fsync equivalent. These records are explicitly
    # replay-safe, so a lingering source after a crash is recovered by normal
    # deduplication instead of weakening durable replacement.
    def self.delete_replay_safe(path : String) : Nil
      File.delete(path)
    end
  end
end
