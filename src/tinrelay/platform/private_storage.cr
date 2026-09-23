{% if flag?(:win32) %}
  require "./private_storage/windows"
{% elsif flag?(:darwin) || flag?(:linux) %}
  require "./private_storage/posix"
{% else %}
  {% raise "TinRelay does not support this platform" %}
{% end %}

module Tinrelay
  module PrivateStorage
    def self.prepare_directory(path : String) : Nil
      Dir.mkdir_p(path, mode: 0o700) unless Dir.exists?(path)
      secure(path, 0o700)
    end

    def self.with_lock(path : String, mode : String, wait : Bool,
                       conflict : Exception? = nil, &)
      File.open(path, mode, perm: 0o600) do |file|
        secure(file.path, 0o600)
        begin
          file.flock_exclusive(wait)
        rescue ex : IO::Error
          raise conflict if conflict
          raise ex
        end
        begin
          yield file
        ensure
          file.flock_unlock
        end
      end
    end
  end
end
