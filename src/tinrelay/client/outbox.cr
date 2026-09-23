module Tinrelay
  class Outbox
    getter directory : String

    def initialize(@directory)
      ensure_directory
    end

    def store(envelope : SignedRelayEnvelope) : String
      encoded = envelope.to_json
      target = path(envelope.transmission_id)
      AtomicPrivateFile.write(target, encoded + '\n')
      encoded
    end

    def read(id : String) : Tuple(SignedRelayEnvelope, String)
      target = path(id)
      encoded = File.read(target).strip
      envelope = SignedRelayEnvelope.from_json(encoded)
      unless envelope.transmission_id == id
        raise Invalid.new("outbox transmission id does not match its file")
      end
      {envelope, encoded}
    rescue ex : File::NotFoundError
      raise NotFound.new("outbox transmission not found")
    rescue ex : JSON::ParseException
      raise Invalid.new("outbox transmission is invalid")
    end

    def list(now : Int64 = Time.utc.to_unix) : Array(SignedRelayEnvelope)
      cleanup(now)
      Dir.children(directory).sort.compact_map do |name|
        next unless name.ends_with?(".json")
        id = File.basename(name, ".json")
        next unless Ids::PROTOCOL_UUID.matches?(id)
        read(id)[0]
      end
    end

    def delete(id : String) : Nil
      target = path(id)
      return unless File.exists?(target)
      PrivateStorage.delete_replay_safe(target)
    end

    def cleanup(now : Int64 = Time.utc.to_unix) : Int32
      removed = 0
      Dir.each_child(directory) do |name|
        next unless name.ends_with?(".json")
        next unless Ids::PROTOCOL_UUID.matches?(File.basename(name, ".json"))
        file = File.join(directory, name)
        begin
          envelope = SignedRelayEnvelope.from_json(File.read(file))
          next if envelope.expires_at > now
          PrivateStorage.delete_replay_safe(file)
          removed += 1
        rescue JSON::ParseException
          # Preserve malformed evidence for deliberate inspection.
        end
      end
      removed
    end

    private def path(id : String) : String
      raise Invalid.new("invalid transmission id") unless Ids::PROTOCOL_UUID.matches?(id)
      File.join(directory, "#{id}.json")
    end

    private def ensure_directory : Nil
      PrivateStorage.prepare_directory(directory)
    end
  end
end
