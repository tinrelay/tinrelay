module Tinrelay
  class OutgoingStore
    getter root : String
    getter outbox_directory : String
    getter sent_directory : String
    getter withdrawals_directory : String
    getter ship : String

    def initialize(@root, @ship)
      Names.ship!(ship)
      @outbox_directory = File.join(root, "outbox")
      @sent_directory = File.join(root, "sent")
      @withdrawals_directory = File.join(root, "withdrawals")
      [root, outbox_directory, sent_directory, withdrawals_directory].each do |directory|
        PrivateStorage.prepare_directory(directory)
      end
    end

    def store(record : OutgoingRecord) : OutgoingRecord
      verify_record!(record)
      encoded = encode(record)
      with_lock do
        if path = existing_paths(record.transmission_id).find { |candidate| File.file?(candidate) }
          unless File.read(path) == encoded
            raise Conflict.new("transmission id already names different outgoing evidence")
          end
          next record_at(path, record.transmission_id)
        end
        AtomicPrivateFile.write(outbox_path(record.transmission_id), encoded)
        record
      end
    end

    def settle(transmission_id : String) : OutgoingRecord
      validate_id!(transmission_id)
      with_lock do
        source = outbox_path(transmission_id)
        destination = sent_path(transmission_id)
        if File.file?(destination)
          record = record_at(destination, transmission_id)
          if File.file?(source)
            unless File.read(source) == File.read(destination)
              raise Conflict.new("sent correspondence differs from retained outbox evidence")
            end
            delete_if_present(source)
          end
          next record
        end
        raise NotFound.new("outbox correspondence not found") unless File.file?(source)
        record = record_at(source, transmission_id)
        PrivateStorage.replace(source, destination)
        record
      end
    rescue ex : File::NotFoundError
      if File.file?(sent_path(transmission_id))
        return record_at(sent_path(transmission_id), transmission_id)
      end
      raise Error.new("outgoing correspondence disappeared while settling")
    end

    def discard_initial(record : OutgoingRecord) : Nil
      verify_record!(record)
      expected = encode(record)
      with_lock do
        path = outbox_path(record.transmission_id)
        next unless File.file?(path)
        unless File.read(path) == expected
          raise Conflict.new("retained outbox evidence changed before rejection cleanup")
        end
        delete_if_present(path)
      end
    end

    def outbox(transmission_id : String) : OutgoingRecord
      validate_id!(transmission_id)
      path = outbox_path(transmission_id)
      raise NotFound.new("outbox correspondence not found") unless File.file?(path)
      record_at(path, transmission_id)
    rescue File::NotFoundError
      raise NotFound.new("outbox correspondence not found")
    end

    def sent(transmission_id : String) : OutgoingRecord
      validate_id!(transmission_id)
      path = sent_path(transmission_id)
      raise NotFound.new("sent correspondence not found") unless File.file?(path)
      record_at(path, transmission_id)
    rescue File::NotFoundError
      raise NotFound.new("sent correspondence not found")
    end

    def list_outbox : Array(OutgoingRecord)
      list_records(outbox_directory)
    end

    def list_sent : Array(OutgoingRecord)
      list_records(sent_directory)
    end

    def outbox?(transmission_id : String) : Bool
      validate_id!(transmission_id)
      File.file?(outbox_path(transmission_id))
    end

    def retryable?(record : OutgoingRecord,
                   now : Int64 = Time.utc.to_unix) : Bool
      record.signed_relay_envelope.expires_at > now
    end

    def mark_withdrawal(transmission_id : String) : Nil
      sent(transmission_id)
      marker = OutgoingWithdrawalMarker.new(transmission_id)
      encoded = marker.to_pretty_json + '\n'
      with_lock do
        path = withdrawal_path(transmission_id)
        if File.file?(path)
          marker_at(path, transmission_id)
          unless File.read(path) == encoded
            raise Conflict.new("withdrawal marker differs from accepted local fact")
          end
          next
        end
        AtomicPrivateFile.write(path, encoded)
      end
    end

    def withdrawal_requested?(transmission_id : String) : Bool
      validate_id!(transmission_id)
      path = withdrawal_path(transmission_id)
      return false unless File.file?(path)
      marker_at(path, transmission_id)
      true
    end

    def outbox_path(transmission_id : String) : String
      validate_id!(transmission_id)
      File.join(outbox_directory, "#{transmission_id}.json")
    end

    def sent_path(transmission_id : String) : String
      validate_id!(transmission_id)
      File.join(sent_directory, "#{transmission_id}.json")
    end

    def withdrawal_path(transmission_id : String) : String
      validate_id!(transmission_id)
      File.join(withdrawals_directory, "#{transmission_id}.json")
    end

    private def list_records(directory : String) : Array(OutgoingRecord)
      records = Dir.children(directory).sort.compact_map do |name|
        next unless name.ends_with?(".json")
        transmission_id = File.basename(name, ".json")
        next unless Ids::PROTOCOL_UUID.matches?(transmission_id)
        begin
          record_at(File.join(directory, name), transmission_id)
        rescue Error | IO::Error | JSON::ParseException | JSON::SerializableError
          nil
        end
      end
      records.sort_by { |record| record.signed_transmission.created_at }.reverse
    end

    private def record_at(path : String, transmission_id : String) : OutgoingRecord
      unless PrivateStorage.private?(path)
        raise Error.new("outgoing correspondence must be private to the current user")
      end
      record = OutgoingRecord.from_json(File.read(path))
      unless record.transmission_id == transmission_id
        raise Error.new("outgoing correspondence id does not match its file")
      end
      verify_record!(record)
      record
    rescue ex : JSON::ParseException | JSON::SerializableError
      raise Error.new("outgoing correspondence is corrupt: #{File.basename(path)}")
    end

    private def marker_at(path : String, transmission_id : String) : OutgoingWithdrawalMarker
      unless PrivateStorage.private?(path)
        raise Error.new("withdrawal marker must be private to the current user")
      end
      marker = OutgoingWithdrawalMarker.from_json(File.read(path))
      unless marker.format == 1 && marker.transmission_id == transmission_id
        raise Error.new("withdrawal marker does not match its file")
      end
      marker
    rescue ex : JSON::ParseException | JSON::SerializableError
      raise Error.new("withdrawal marker is corrupt: #{File.basename(path)}")
    end

    private def verify_record!(record : OutgoingRecord) : Nil
      unless record.format == 1
        raise Error.new("unsupported outgoing correspondence format")
      end
      transmission = record.signed_transmission
      envelope = record.signed_relay_envelope
      certificate = record.authoring_radio_certificate
      owner = record.authoring_owner
      unless transmission.object_version == 1 && envelope.object_version == 1 &&
             transmission.protocol == PROTOCOL && envelope.protocol == PROTOCOL
        raise Error.new("unsupported outgoing correspondence protocol")
      end
      unless transmission.sender_ship == ship && envelope.sender_ship == ship
        raise Error.new("outgoing correspondence belongs to another local ship")
      end
      unless certificate.identifies_sender?(
               transmission.sender_ship, transmission.sender_signing_generation
             ) && certificate.owner_generation == owner.generation
        raise Error.new("outgoing authoring evidence does not identify its transmission")
      end
      unless certificate.owner_authorized?(Crypto.unb64(owner.public_key))
        raise Error.new("outgoing radio certificate is not owner-authorized")
      end
      signing_key = Crypto.unb64(certificate.signing_public_key)
      unless Crypto.verify(
               transmission.signing_bytes,
               Crypto.unb64(transmission.signature), signing_key
             )
        raise Error.new("outgoing signed transmission verification failed")
      end
      unless Crypto.verify(
               envelope.signing_bytes,
               Crypto.unb64(envelope.signature), signing_key
             )
        raise Error.new("outgoing relay envelope verification failed")
      end
      unless transmission.matches_envelope?(envelope)
        raise Error.new("outgoing plaintext and relay envelope routing facts differ")
      end
    rescue ex : Invalid
      raise Error.new("outgoing correspondence contains invalid cryptographic evidence")
    end

    private def encode(record : OutgoingRecord) : String
      record.to_pretty_json + '\n'
    end

    private def existing_paths(transmission_id : String) : Array(String)
      [outbox_path(transmission_id), sent_path(transmission_id)]
    end

    private def validate_id!(transmission_id : String) : Nil
      unless Ids::PROTOCOL_UUID.matches?(transmission_id)
        raise Invalid.new("invalid transmission id")
      end
    end

    private def with_lock(&block : -> T) : T forall T
      path = File.join(root, "outgoing.lock")
      PrivateStorage.with_lock(path, "a", true) do |_file|
        block.call
      end
    end

    private def delete_if_present(path : String) : Nil
      PrivateStorage.delete_replay_safe(path)
    rescue File::NotFoundError
    end
  end
end
