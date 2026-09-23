module Tinrelay
  class Client
    # Contact-close is the only radio-generation transition. One prospective
    # identity is saved before submission; registry state either promotes that
    # exact identity or leaves it pending for an exact retry after restart.
    def sync_radio! : Bool
      refresh_keyring!
      document = inspect_document(keyring.data.ship, all_local_radios: true)
      active = document["radio_keys"].as_a.find { |item| item["state"].as_s == "active" } ||
               raise Unavailable.new("ship has no active radio")
      generation = active["generation"].as_i.to_i
      mutate_keyring do
        if pending = keyring.data.pending_radio
          if radio_matches_document?(pending, active)
            promote_pending_radio!(pending)
            next true
          end
        end
        local = keyring.data.radios.find do |radio|
          radio.generation == generation &&
            radio_matches_document?(radio, active)
        end || raise Unauthorized.new(
          "active registry radio has no matching local private key"
        )
        next false if keyring.data.active_radio_generation == local.generation
        keyring.data.active_radio_generation = local.generation
        false
      end
    end

    def close_contact(peer_ship : String) : Int32
      peer = Names.ship!(peer_ship)
      mutate_keyring { keyring.block!(peer) }
      if reconcile_radio_if_pending!
        return keyring.data.active_radio_generation
      end
      sync_owner!
      fresh_identity = false
      identity, prior_signature, retained = mutate_keyring_with_owner do |owner|
        contact = keyring.block!(peer)
        prior = keyring.data.radio!
        fresh_identity = keyring.data.pending_radio.nil?
        pending = keyring.data.pending_radio || build_pending_radio!(prior, owner)
        signature = Crypto.b64(
          Crypto.sign(
            pending.certificate.unsigned_bytes,
            Crypto.unb64(prior.signing.secret_key)
          )
        )
        peers = keyring.data.contacts.reject do |item|
          item.ship == contact.ship || item.blocked?
        end.map(&.ship).sort
        {pending, signature, peers}
      end
      certificate = identity.certificate
      provisional = RelationshipClose.new(
        peer, retained, certificate, prior_signature,
        unsigned_owner_auth
      )
      provisional.auth = owner_auth("relationship.close", provisional.payload)
      begin
        remote.post("/v1/relationships/close", provisional.to_json)
      rescue ex : RotationLimited
        clear_pending_radio!(identity) if fresh_identity
        raise ex
      rescue ex : Invalid | Unauthorized | NotFound | Conflict | Expired | ProtocolMismatch
        clear_pending_radio!(identity) if fresh_identity
        raise ex
      rescue ex : Unavailable | Error | IO::Error
        begin
          return identity.generation if sync_radio!
        rescue
          # The exact pending identity remains durable for a later retry.
        end
        raise ex
      end
      mutate_keyring { promote_pending_radio!(identity) }
      identity.generation
    end

    def allow_contact(hail_id : String, spool : Spool) : ShipContact
      record = spool.get("hail", hail_id).as?(HailSpoolRecord) ||
               raise Invalid.new("local inbox item is not a hail")
      peer = Names.ship!(record.sender_ship)
      mutate_keyring do
        unless record.recipient_ship == keyring.data.ship
          raise Invalid.new("hail belongs to another recipient")
        end
        prior = keyring.data.contacts.find { |contact| contact.ship == peer }
        raise Unauthorized.new("contact is locally blocked") if prior.try(&.blocked?)
        verify_hail_record!(record, prior)
      end
      request = RelationshipAllow.new(
        peer, record.hail_id, unsigned_radio_auth
      )
      request.auth = radio_auth("relationship.allow", request.payload)
      remote.post("/v1/relationships/allow", request.to_json)
      mutate_keyring do
        prior = keyring.data.contacts.find { |contact| contact.ship == peer }
        raise Unauthorized.new("contact is locally blocked") if prior.try(&.blocked?)
        verify_hail_record!(record, prior)
        keyring.pin_hail(record)
      end
    end

    def unblock_contact(peer_ship : String) : ShipContact
      mutate_keyring { keyring.unblock!(peer_ship) }
    end

    def rotate_owner : Int32
      reconcile_radio_if_pending!
      if keyring.data.pending_radio
        raise Conflict.new(
          "finish the pending contact close radio retune before rotating the owner key"
        )
      end
      return keyring.data.owner_generation if sync_owner!
      fresh_identity = false
      new_generation, pending_key, prior_signature = mutate_keyring_with_owner do |owner|
        if keyring.data.pending_radio
          raise Conflict.new(
            "finish the pending contact close radio retune before rotating the owner key"
          )
        end
        generation = keyring.data.owner_generation + 1
        pending_generation = owner.pending_generation
        pending = owner.pending_key
        if pending_generation.nil? != pending.nil?
          raise Error.new("pending owner identity is incomplete")
        end
        if pending_generation && pending_generation != generation
          raise Error.new("pending owner identity has an unexpected generation")
        end
        fresh_identity = pending.nil?
        unless pending
          keys = Crypto.signing_keypair
          pending = StoredKeyPair.from_raw(keys.public_key, keys.secret_key)
          owner.pending_generation = generation
          owner.pending_key = pending
        end
        bytes = OwnerKeyLink.rotation_bytes(keyring.data.ship, generation, pending.public_key)
        signature = Crypto.b64(
          Crypto.sign(bytes, Crypto.unb64(owner.key.secret_key))
        )
        {generation, pending, signature}
      end
      new_public = pending_key.public_key
      provisional = OwnerRotation.new(
        new_generation, new_public, prior_signature,
        unsigned_owner_auth
      )
      provisional.auth = owner_auth("owner.rotate", provisional.payload)
      begin
        remote.post("/v1/owners/rotate", provisional.to_json)
      rescue ex : RotationLimited
        return new_generation if owner_rotation_committed?(new_generation)
        clear_pending_owner!(new_generation, pending_key) if fresh_identity
        raise ex
      rescue ex : Invalid | Unauthorized | NotFound | Conflict | Expired | ProtocolMismatch
        return new_generation if owner_rotation_committed?(new_generation)
        clear_pending_owner!(new_generation, pending_key) if fresh_identity
        raise ex
      rescue ex : Unavailable | Error | IO::Error
        return new_generation if owner_rotation_committed?(new_generation)
        # An uncertain or previously reused identity remains durable for the
        # next exact retry; never create a sibling key at this generation.
        raise ex
      end
      mutate_keyring_with_owner do |owner|
        promote_owner!(owner, new_generation, pending_key)
      end
      new_generation
    end

    def ship_change(operation : String) : Nil
      sync_owner!
      provisional = ShipChange.new(operation, unsigned_owner_auth)
      provisional.auth = owner_auth("ship.change", provisional.payload)
      remote.post("/v1/ships/change", provisional.to_json)
    end

    private def owner_auth(action : String, payload : Bytes) : OwnerAuth
      document = inspect_document(keyring.data.ship, all_local_radios: true)
      admin_generation = document["admin_generation"].as_i64 + 1
      auth = OwnerAuth.new(
        keyring.data.ship, keyring.data.owner_generation,
        admin_generation, Time.utc.to_unix
      )
      owner = keyring.owner
      auth.signature = Crypto.b64(
        Crypto.sign(auth.signing_bytes(action, payload), Crypto.unb64(owner.key.secret_key))
      )
      auth
    end

    private def unsigned_owner_auth : OwnerAuth
      OwnerAuth.new(keyring.data.ship, keyring.data.owner_generation, 0_i64, 0_i64)
    end

    private def sync_owner! : Bool
      refresh_keyring!
      document = inspect_document(keyring.data.ship, all_local_radios: true)
      active = document["owner_keys"].as_a.find { |item| item["state"].as_s == "active" } ||
               raise Unavailable.new("ship has no active owner key")
      generation = active["generation"].as_i.to_i
      public_key = active["public_key"].as_s
      mutate_keyring_with_owner do |owner|
        next false if generation == owner.generation && public_key == owner.key.public_key
        if owner.pending_generation == generation &&
           owner.pending_key.try(&.public_key) == public_key
          promote_owner!(owner, generation, owner.pending_key.not_nil!)
          next true
        end
        raise Unauthorized.new("active registry owner has no matching local private key")
      end
    end

    private def owner_rotation_committed?(generation : Int32) : Bool
      sync_owner!
      keyring.data.owner_generation == generation
    rescue
      false
    end

    private def clear_pending_owner!(generation : Int32, key : StoredKeyPair) : Nil
      mutate_keyring_with_owner do |owner|
        if owner.pending_generation == generation &&
           owner.pending_key.try(&.to_json) == key.to_json
          owner.pending_generation = nil
          owner.pending_key = nil
        end
      end
    end

    private def reconcile_radio_if_pending! : Bool
      refresh_keyring!
      return false unless keyring.data.pending_radio
      sync_radio!
    end

    private def build_pending_radio!(prior : ShipRadioIdentity,
                                     owner : OwnerKeyData) : ShipRadioIdentity
      generation = prior.generation + 1
      identity = ShipRadioIdentity.create_signed(
        keyring.data.ship, generation, keyring.data.owner_generation,
        owner.key, Time.utc.to_unix
      )
      keyring.data.pending_radio = identity
      identity
    end

    private def promote_pending_radio!(identity : ShipRadioIdentity) : Nil
      unless pending = keyring.data.pending_radio
        active = keyring.data.radio!
        return if active.to_json == identity.to_json
        raise Conflict.new("no pending contact close radio identity")
      end
      unless pending.to_json == identity.to_json
        raise Conflict.new("pending contact close radio identity changed")
      end
      prior = keyring.data.radio!
      prior.retire_after = Time.utc.to_unix + FALLBACK_LIFETIME_SECONDS
      keyring.data.radios << identity unless keyring.data.radios.any? do |radio|
                                               radio.generation == identity.generation
                                             end
      keyring.data.active_radio_generation = identity.generation
      keyring.data.pending_radio = nil
    end

    private def clear_pending_radio!(identity : ShipRadioIdentity) : Nil
      mutate_keyring do
        pending = keyring.data.pending_radio
        keyring.data.pending_radio = nil if pending.try(&.to_json) == identity.to_json
      end
    end

    private def radio_matches_document?(radio : ShipRadioIdentity,
                                        document : JSON::Any) : Bool
      radio.generation == document["generation"].as_i &&
        radio.signing.public_key == document["signing_public_key"].as_s &&
        radio.encryption.public_key == document["encryption_public_key"].as_s
    end

    private def promote_owner!(owner : OwnerKeyData, generation : Int32,
                               key : StoredKeyPair) : Nil
      if owner.generation == generation && owner.key.to_json == key.to_json &&
         keyring.data.owner_generation == generation &&
         keyring.data.owner_public_key == key.public_key
        return
      end
      unless owner.pending_generation == generation &&
             owner.pending_key.try(&.to_json) == key.to_json &&
             keyring.data.owner_generation == generation - 1
        raise Conflict.new("pending owner identity changed")
      end
      owner.generation = generation
      owner.key = key
      owner.pending_generation = nil
      owner.pending_key = nil
      keyring.data.owner_generation = generation
      keyring.data.owner_public_key = key.public_key
    end
  end
end
