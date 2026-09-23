module Tinrelay
  class StoredKeyPair
    include JSON::Serializable

    property public_key : String
    property secret_key : String

    def initialize(@public_key, @secret_key)
    end

    def self.from_raw(public_key : Bytes, secret_key : Bytes) : StoredKeyPair
      new(Crypto.b64(public_key), Crypto.b64(secret_key))
    end
  end

  class ShipRadioIdentity
    include JSON::Serializable

    property generation : Int32
    property signing : StoredKeyPair
    property encryption : StoredKeyPair
    property certificate : ShipRadioCertificate
    property retire_after : Int64?
    property owner_public_key : String?

    def initialize(@generation, @signing, @encryption, @certificate,
                   @retire_after = nil, @owner_public_key = nil)
    end

    def self.create_signed(ship : String, generation : Int32,
                           owner_generation : Int32, owner : StoredKeyPair,
                           issued_at : Int64) : ShipRadioIdentity
      signing = Crypto.signing_keypair
      encryption = Crypto.box_keypair
      certificate = ShipRadioCertificate.new(
        ship, generation, Crypto.b64(signing.public_key),
        Crypto.b64(encryption.public_key), issued_at, owner_generation
      )
      certificate.owner_signature = Crypto.b64(
        Crypto.sign(certificate.unsigned_bytes, Crypto.unb64(owner.secret_key))
      )
      new(
        generation, StoredKeyPair.from_raw(signing.public_key, signing.secret_key),
        StoredKeyPair.from_raw(encryption.public_key, encryption.secret_key),
        certificate, owner_public_key: owner.public_key
      )
    end
  end

  class ShipContact
    include JSON::Serializable

    property ship : String
    property owner_generation : Int32
    property owner_public_key : String
    property owner_chain : Array(OwnerKeyLink)
    property radio_certificate : ShipRadioCertificate
    property default_label : String
    property pinned_at : Int64
    property blocked_at : Int64?

    def initialize(@ship, @owner_generation, @owner_public_key,
                   @radio_certificate, @default_label,
                   @pinned_at = Time.utc.to_unix, @blocked_at = nil,
                   owner_chain : Array(OwnerKeyLink)? = nil)
      @owner_chain = owner_chain || [OwnerKeyLink.new(@owner_generation, @owner_public_key)]
    end

    def blocked? : Bool
      !blocked_at.nil?
    end

    def adopt_verified_identity!(chain : Array(OwnerKeyLink),
                                 certificate : ShipRadioCertificate) : Nil
      current_owner = chain.last
      @owner_chain = chain
      @owner_generation = current_owner.generation
      @owner_public_key = current_owner.public_key
      @radio_certificate = certificate
    end
  end

  class KeyringData
    include JSON::Serializable

    property format : Int32
    property server : String
    property ship : String
    property owner_generation : Int32
    property owner_public_key : String
    property active_radio_generation : Int32
    property radios : Array(ShipRadioIdentity)
    property pending_radio : ShipRadioIdentity?
    property contacts : Array(ShipContact)

    def initialize(@server, @ship, @owner_public_key, @radios,
                   @owner_generation = 1,
                   @active_radio_generation = 1,
                   @pending_radio = nil,
                   @contacts = [] of ShipContact,
                   @format = 2)
    end

    def radio!(generation : Int32? = nil) : ShipRadioIdentity
      wanted = generation || active_radio_generation
      identity = radios.find { |radio| radio.generation == wanted }
      identity || raise NotFound.new("ship radio key is not in this keyring")
    end

    def contact!(ship : String) : ShipContact
      contacts.find { |contact| contact.ship == ship } ||
        raise NotFound.new("ship #{ship} is not pinned")
    end
  end

  class OwnerKeyData
    include JSON::Serializable

    property format : Int32
    property ship : String
    property generation : Int32
    property key : StoredKeyPair
    property pending_generation : Int32?
    property pending_key : StoredKeyPair?

    def initialize(@ship, @generation, @key,
                   @pending_generation = nil, @pending_key = nil,
                   @format = 1)
    end
  end

  private class ProvisionalClaimOwner
    include JSON::Serializable

    getter token : String
    getter identity_digest : String
    property shared : Bool

    def initialize(@token, @identity_digest, @shared = false)
    end
  end

  private record JoinKeyring, keyring : Keyring, cleanup_token : String?

  class Keyring
    getter path : String
    getter owner_path : String
    getter data : KeyringData

    @source_digest : String?

    def initialize(@path, @owner_path, @data, @source_digest = nil)
    end

    def self.create(path : String, server : String, ship : String,
                    owner_path : String? = nil,
                    now : Time = Time.utc) : Keyring
      Names.ship!(ship)
      owner_file = owner_path || "#{path}.owner"
      synchronize_path(path) do
        raise Conflict.new("keyring already exists") if File.exists?(path)
        raise Conflict.new("owner key file already exists") if File.exists?(owner_file)
        create_unlocked(path, server, ship, owner_file, now)
      end
    end

    def self.prepare_join(path : String, server : String, ship : String,
                          owner_path : String? = nil,
                          now : Time = Time.utc) : JoinKeyring
      Names.ship!(ship)
      owner_file = owner_path || "#{path}.owner"
      synchronize_path(path) do |lock|
        if File.exists?(path) || File.exists?(owner_file)
          keyring = load_unlocked(path, owner_file)
          keyring.owner_unlocked
          unless keyring.data.server == server && keyring.data.ship == ship
            raise Unauthorized.new("existing provisional keyring does not match this claim")
          end
          if marker = read_claim_owner(lock)
            if marker.identity_digest == keyring.identity_digest
              marker.shared = true
              write_claim_owner(lock, marker)
            end
          end
          JoinKeyring.new(keyring, nil)
        else
          keyring = create_unlocked(path, server, ship, owner_file, now)
          token = Ids.uuid
          write_claim_owner(
            lock,
            ProvisionalClaimOwner.new(token, keyring.identity_digest)
          )
          JoinKeyring.new(keyring, token)
        end
      end
    end

    def finish_join : Nil
      self.class.synchronize_path(path) do |lock|
        marker = self.class.read_claim_owner(lock)
        current = self.class.load_unlocked(path, owner_path)
        current.owner_unlocked
        unless current.identity_digest == identity_digest
          raise Conflict.new("provisional ship identity changed during registration")
        end
        if marker && marker.identity_digest == current.identity_digest
          self.class.clear_claim_owner(lock)
        end
      end
    end

    def abandon_join(cleanup_token : String) : Nil
      self.class.synchronize_path(path) do |lock|
        marker = self.class.read_claim_owner(lock)
        next unless marker && marker.token == cleanup_token && !marker.shared
        next unless marker.identity_digest == identity_digest
        current = begin
          loaded = self.class.load_unlocked(path, owner_path)
          loaded.owner_unlocked
          loaded
        rescue
          nil
        end
        next unless current && current.identity_digest == marker.identity_digest
        File.delete(path) if File.exists?(path)
        File.delete(owner_path) if File.exists?(owner_path)
        self.class.clear_claim_owner(lock)
      end
    end

    def self.load(path : String, owner_path : String? = nil) : Keyring
      synchronize_path(path) do
        load_unlocked(path, owner_path)
      end
    end

    protected def self.load_unlocked(path : String,
                                     owner_path : String? = nil) : Keyring
      encoded = read_private(path, "keyring")
      load_encoded(path, owner_path, encoded)
    end

    protected def self.load_encoded(path : String, owner_path : String?,
                                    encoded : String) : Keyring
      data = KeyringData.from_json(encoded)
      raise Invalid.new("unsupported ship keyring format") unless data.format == 2
      new(
        path, owner_path || "#{path}.owner", data,
        Digest::SHA256.hexdigest(encoded)
      )
    rescue ex : JSON::ParseException | JSON::SerializableError
      raise Invalid.new("keyring file is invalid")
    end

    protected def identity_digest : String
      Digest::SHA256.hexdigest(
        Canonical.fields(data.owner_public_key, data.radio!(1).certificate.to_json)
      )
    end

    def owner : OwnerKeyData
      owner = nil.as(OwnerKeyData?)
      self.class.synchronize_path(path) do
        owner = owner_unlocked
      end
      owner.not_nil!
    end

    def mutate(include_owner : Bool = false,
               & : Keyring, OwnerKeyData? -> T) : T forall T
      result = nil.as(T?)
      self.class.synchronize_path(path) do
        latest = reload_unlocked
        unless latest.data.server == data.server && latest.data.ship == data.ship
          raise Unauthorized.new("keyring path now belongs to another ship identity")
        end
        owner = include_owner ? latest.owner_unlocked : nil
        before_data = latest.data.to_json
        before_owner = owner.try(&.to_json)
        result = yield latest, owner
        latest.persist_owner(owner.not_nil!) if owner && owner.to_json != before_owner
        latest.persist if latest.data.to_json != before_data
        @data = latest.data
        @source_digest = latest.source_digest
      end
      result.as(T)
    end

    def refresh : Keyring
      mutate { |_latest, _owner| nil }
      self
    end

    protected def owner_unlocked : OwnerKeyData
      encoded = self.class.read_private(owner_path, "owner key")
      owner = self.class.load_plain_owner(encoded)
      self.class.validate_owner!(data, owner)
      owner
    rescue ex : JSON::ParseException | JSON::SerializableError
      raise Invalid.new("owner key file is invalid")
    end

    protected def persist_owner(owner : OwnerKeyData) : Nil
      AtomicPrivateFile.write(owner_path, owner.to_pretty_json + '\n')
    end

    def save : Nil
      desired = data.to_json
      self.class.synchronize_path(path) do
        unless Digest::SHA256.hexdigest(File.read(path)) == source_digest
          raise Conflict.new("keyring changed since it was loaded")
        end
        @data = KeyringData.from_json(desired)
        persist
      end
    end

    protected def persist : Nil
      encoded = data.to_pretty_json + '\n'
      AtomicPrivateFile.write(path, encoded)
      @source_digest = Digest::SHA256.hexdigest(encoded)
    end

    protected def source_digest : String
      @source_digest || raise(Error.new("keyring has no persisted source"))
    end

    # The exact private-file bytes are the cheap freshness token. Most collector
    # turns can reuse their parsed snapshot; a changed file is reread under the lock.
    private def reload_unlocked : Keyring
      encoded = self.class.read_private(path, "keyring")
      if Digest::SHA256.hexdigest(encoded) == source_digest
        return Keyring.new(
          path, owner_path, KeyringData.from_json(data.to_json), source_digest
        )
      end
      self.class.load_encoded(path, owner_path, encoded)
    end

    protected def self.synchronize_path(path : String, &)
      directory = File.dirname(path)
      PrivateStorage.prepare_directory(directory)
      PrivateStorage.with_lock("#{path}.lock", "a+", true) do |file|
        yield file
      end
    end

    protected def self.create_unlocked(path : String, server : String,
                                       ship : String,
                                       owner_file : String, now : Time) : Keyring
      owner_keys = Crypto.signing_keypair
      owner = StoredKeyPair.from_raw(owner_keys.public_key, owner_keys.secret_key)
      radio = ShipRadioIdentity.create_signed(ship, 1, 1, owner, now.to_unix)
      keyring = new(
        path, owner_file,
        KeyringData.new(server, ship, owner.public_key, [radio])
      )
      begin
        keyring.persist_owner(OwnerKeyData.new(ship, 1, owner))
        keyring.persist
      rescue ex
        File.delete(owner_file) if File.exists?(owner_file)
        File.delete(path) if File.exists?(path)
        raise ex
      end
      keyring
    end

    protected def self.read_claim_owner(lock : File) : ProvisionalClaimOwner?
      lock.rewind
      encoded = lock.gets_to_end
      return if encoded.empty?
      ProvisionalClaimOwner.from_json(encoded)
    rescue JSON::ParseException | JSON::SerializableError
      nil
    end

    protected def self.write_claim_owner(lock : File,
                                         marker : ProvisionalClaimOwner) : Nil
      lock.rewind
      lock.truncate(0)
      lock << marker.to_json
      lock.flush
      lock.fsync
    end

    protected def self.clear_claim_owner(lock : File) : Nil
      lock.rewind
      lock.truncate(0)
      lock.flush
      lock.fsync
    end

    def pin_hail(record : HailSpoolRecord) : ShipContact
      ship = Names.ship!(record.sender_ship)
      certificate = record.sender_radio_certificate
      owner = record.sender_owner_chain.last? ||
              raise Invalid.new("hail has no ship owner identity")
      prior = data.contacts.find { |item| item.ship == ship }
      return prior if prior
      contact = ShipContact.new(
        ship, owner.generation, owner.public_key, certificate,
        "unresolved",
        owner_chain: record.sender_owner_chain
      )
      data.contacts << contact
      contact
    end

    def block!(ship : String, now : Int64 = Time.utc.to_unix) : ShipContact
      contact = data.contact!(Names.ship!(ship))
      contact.blocked_at ||= now
      contact
    end

    def unblock!(ship : String) : ShipContact
      contact = data.contact!(Names.ship!(ship))
      contact.blocked_at = nil
      contact
    end

    def prune_retired_radios!(now : Int64 = Time.utc.to_unix) : Bool
      before = data.radios.size
      data.radios.reject! do |radio|
        radio.generation != data.active_radio_generation &&
          radio.retire_after.try { |deadline| deadline <= now }
      end
      data.radios.size != before
    end

    protected def self.read_private(path : String, label : String) : String
      raise NotFound.new("#{label} not found: #{path}") unless File.file?(path)
      unless PrivateStorage.private?(path)
        raise Invalid.new("#{label} must be private to the current user")
      end
      File.read(path)
    end

    protected def self.load_plain_owner(encoded : String) : OwnerKeyData
      owner = OwnerKeyData.from_json(encoded)
      raise Invalid.new("unsupported owner key format") unless owner.format == 1
      owner
    end

    protected def self.validate_owner!(data : KeyringData, owner : OwnerKeyData) : Nil
      unless owner.ship == data.ship && owner.generation == data.owner_generation &&
             owner.key.public_key == data.owner_public_key
        raise Unauthorized.new("owner key does not match the ship keyring")
      end
    end
  end
end
