module Tinrelay
  # Temporary one-shot conversion from local evidence aliases to source identities.
  class LocalStateMigration
    OLD_ID = /\Atr_[0-9a-f]{32}\z/

    private class Conversion
      getter old_path : String
      property new_path : String
      getter old_id : String
      getter kind : String
      getter source_id : String
      getter bytes : String

      def initialize(@old_path, @new_path, @old_id, @kind, @source_id, @bytes)
      end
    end

    def initialize(@paths : LocalPaths)
    end

    def run : Nil
      spool_root = @paths.spool
      pending_target = @paths.pending_target
      return unless Dir.exists?(spool_root) || File.file?(pending_target)
      unless Dir.exists?(spool_root)
        raise Invalid.new("TinRelay inbox is missing for bridge recovery state")
      end

      with_lock(@paths.local_delivery_lock) do
        with_lock(File.join(spool_root, "radio-wait.lock")) do
          conversions = conversions(spool_root)
          identity_by_old_id = identity_map(spool_root, conversions)
          target_bytes = pending_target_bytes(pending_target, identity_by_old_id)
          validate_records(spool_root, conversions)
          apply(conversions, pending_target, target_bytes)
          Spool.open_existing(spool_root).list
        end
      end
    end

    private def conversions(root : String) : Array(Conversion)
      items = [] of Conversion
      {"pending", "routed"}.each do |state|
        directory = File.join(root, state)
        next unless Dir.exists?(directory)
        Dir.children(directory).sort.each do |name|
          next unless name.ends_with?(".json")
          path = File.join(directory, name)
          next unless File.file?(path)
          old_id = File.basename(name, ".json")
          unless OLD_ID.matches?(old_id)
            raise Invalid.new("legacy inbox record filename is invalid: #{name}")
          end
          value = JSON.parse(File.read(path)).as_h
          kind, source_id, bytes = convert_record(value, old_id)
          new_path = File.join(root, state, kind, "#{source_id}.json")
          items << Conversion.new(path, new_path, old_id, kind, source_id, bytes)
        rescue JSON::ParseException | TypeCastError | KeyError
          raise Invalid.new("legacy inbox record is corrupt: #{name}")
        end
      end
      reconcile_duplicate_states(items)
    end

    private def convert_record(value : Hash(String, JSON::Any), old_id : String)
      unless value["format"].as_i == 1 && value["local_id"].as_s == old_id
        raise Invalid.new("legacy inbox record identity is invalid")
      end
      kind = value["kind"].as_s
      source_id = case kind
                  when "transmission"
                    transmission_id = value["signed_transmission"]["transmission_id"].as_s
                    unless value["relay_transmission_id"].as_s == transmission_id
                      raise Invalid.new("legacy inbox transmission identity is inconsistent")
                    end
                    value.delete("relay_transmission_id")
                    transmission_id
                  when "hail"
                    value["hail"]["hail_id"].as_s
                  when "rejected_transmission"
                    transmission_id = value.delete("relay_transmission_id").not_nil!.as_s
                    value["transmission_id"] = JSON::Any.new(transmission_id)
                    RejectionEvidence.id(transmission_id, value["rejection_reason"].as_s)
                  else
                    raise Invalid.new("legacy inbox record kind is invalid")
                  end
      unless old_id == legacy_id(kind, source_id, value)
        raise Invalid.new("legacy inbox record alias is invalid")
      end
      value.delete("local_id")
      value["format"] = JSON::Any.new(2_i64)
      value["source_id"] = JSON::Any.new(source_id)
      {kind, source_id, JSON::Any.new(value).to_pretty_json + '\n'}
    end

    private def legacy_id(kind, source_id, value)
      source = if kind == "rejected_transmission"
                 "#{value["transmission_id"].as_s}:#{value["rejection_reason"].as_s}"
               else
                 source_id
               end
      digest = Digest::SHA256.hexdigest(
        Canonical.fields(
          "tinrelay-local-evidence-v1",
          kind == "rejected_transmission" ? "rejection" : kind,
          source
        )
      )
      "tr_#{digest[0, 32]}"
    end

    private def reconcile_duplicate_states(items : Array(Conversion))
      items.group_by { |item| {item.kind, item.source_id} }.each_value do |group|
        next if group.size == 1
        unless group.map(&.bytes).uniq.size == 1 && group.size == 2
          raise Conflict.new("legacy inbox contains conflicting source identities")
        end
        routed = group.find { |item| destination_state(item) == "routed" } ||
                 raise Conflict.new("legacy inbox source identity is duplicated")
        group.each { |item| item.new_path = routed.new_path }
      end
      items
    end

    private def identity_map(root, conversions)
      identities = {} of String => Tuple(String, String)
      conversions.each do |item|
        add_identity!(identities, item.old_id, item.kind, item.source_id)
      end
      {"pending", "routed"}.each do |state|
        Ids::SOURCE_KINDS.each do |kind|
          directory = File.join(root, state, kind)
          next unless Dir.exists?(directory)
          Dir.children(directory).each do |name|
            next unless name.ends_with?(".json")
            source_id = File.basename(name, ".json")
            value = JSON.parse(File.read(File.join(directory, name))).as_h
            add_identity!(
              identities, legacy_id(kind, source_id, value), kind, source_id
            )
          end
        end
      end
      identities
    rescue JSON::ParseException | TypeCastError | KeyError
      raise Invalid.new("current inbox record is corrupt")
    end

    private def add_identity!(identities, old_id, kind, source_id)
      identity = {kind, source_id}
      if existing = identities[old_id]?
        unless existing == identity
          raise Conflict.new("legacy inbox aliases more than one source identity")
        end
      else
        identities[old_id] = identity
      end
    end

    private def pending_target_bytes(path, identities)
      return unless File.file?(path)
      value = JSON.parse(File.read(path)).as_h
      return if value.keys.sort == ["kind", "source_id", "state", "task_id"]
      keys = value.keys.sort
      legacy = keys == ["local_id", "task_id"] ||
               keys == ["local_id", "route", "task_id"] ||
               keys == ["local_id", "state", "task_id"]
      raise Invalid.new("bridge pending target is not migratable") unless legacy
      identity = identities[value["local_id"].as_s]? ||
                 raise(Invalid.new("bridge pending target has no matching inbox record"))
      state = value["state"]?.try(&.as_s) || "ready"
      unless {"ready", "delivered", "receipt_unknown"}.includes?(state) &&
             Ids::TASK_UUID.matches?(value["task_id"].as_s)
        raise Invalid.new("bridge pending target is not migratable")
      end
      {
        kind: identity[0], source_id: identity[1],
        task_id: value["task_id"].as_s, state: state,
      }.to_json + '\n'
    rescue JSON::ParseException | TypeCastError | KeyError
      raise Invalid.new("bridge pending target is not migratable")
    end

    private def validate_records(root, conversions)
      spool = Spool.open_existing(root)
      destinations = {} of String => String
      Ids::SOURCE_KINDS.each do |kind|
        {"pending", "routed"}.each do |state|
          directory = File.join(root, state, kind)
          next unless Dir.exists?(directory)
          Dir.children(directory).each do |name|
            next unless name.ends_with?(".json")
            source_id = File.basename(name, ".json")
            bytes = File.read(File.join(directory, name))
            validate_destination!(
              spool, destinations, state, kind, source_id, bytes
            )
          end
        end
      end
      conversions.each do |item|
        validate_destination!(
          spool, destinations, destination_state(item), item.kind,
          item.source_id, item.bytes
        )
      end
    end

    private def destination_state(item)
      File.basename(File.dirname(File.dirname(item.new_path)))
    end

    private def validate_destination!(spool, destinations, state, kind,
                                      source_id, bytes)
      key = "#{state}\0#{kind}\0#{source_id}"
      if existing = destinations[key]?
        unless existing == bytes
          raise Conflict.new("migrated inbox destination differs")
        end
        return
      end
      spool.validate_record_bytes(kind, source_id, bytes)
      destinations[key] = bytes
    end

    private def apply(conversions, pending_target, target_bytes)
      conversions.each do |item|
        PrivateStorage.prepare_directory(File.dirname(item.new_path))
        if File.file?(item.new_path)
          unless File.read(item.new_path) == item.bytes
            raise Conflict.new("migrated inbox destination differs")
          end
        else
          AtomicPrivateFile.write(item.new_path, item.bytes)
        end
      end
      AtomicPrivateFile.write(pending_target, target_bytes) if target_bytes
      conversions.each do |item|
        PrivateStorage.delete_replay_safe(item.old_path)
      rescue File::NotFoundError
      end
    end

    private def with_lock(path, &block : -> T) : T forall T
      PrivateStorage.with_lock(
        path, "a", false, Conflict.new("local TinRelay delivery must stop before migration")
      ) do |_file|
        block.call
      end
    end
  end
end
