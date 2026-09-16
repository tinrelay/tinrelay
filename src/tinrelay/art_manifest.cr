require "json"

module Tinrelay
  class ArtManifest
    MAX_BYTES = 64 * 1024

    def initialize(@stylesheets : Hash(String, String))
    end

    def self.empty : self
      new({} of String => String)
    end

    def self.load(path : String?, allowed_pages : Array(String)) : self
      return empty unless path
      raise Invalid.new("art manifest path must be absolute") unless Path.new(path).absolute?

      bytes = File.open(path) do |file|
        buffer = IO::Memory.new
        count = IO.copy(file, buffer, MAX_BYTES + 1)
        if count > MAX_BYTES
          raise Invalid.new("art manifest exceeds #{MAX_BYTES} bytes")
        end
        buffer.to_s
      end
      stylesheets = Hash(String, String).from_json(bytes)
      stylesheets.each do |page, stylesheet|
        unless allowed_pages.includes?(page)
          raise Invalid.new("art manifest page is unknown: #{page}")
        end
        unless stylesheet_path?(stylesheet)
          raise Invalid.new("art manifest stylesheet must be a root-relative CSS path")
        end
      end
      new(stylesheets)
    rescue ex : File::Error
      raise Invalid.new("art manifest cannot be read")
    rescue ex : JSON::ParseException | JSON::SerializableError
      raise Invalid.new("art manifest must be a JSON object of page names to stylesheet paths")
    end

    def stylesheet(page : String) : String?
      @stylesheets[page]?
    end

    private def self.stylesheet_path?(path : String) : Bool
      return false if path.bytesize > 2048
      return false unless path.matches?(/\A\/[A-Za-z0-9._\/-]+\.css\z/)
      path[1..].split('/').all? do |part|
        !part.empty? && part != "." && part != ".."
      end
    end
  end
end
