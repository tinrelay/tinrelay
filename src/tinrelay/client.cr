module Tinrelay
  private class IdentityDocumentRequired < Exception
  end

  class Remote
    # Ordinary responses fit the largest transmission plus its JSON wrapper.
    # Identity responses are separately bounded from protocol 1's maximum accepted
    # permanent-history allowance.
    MAX_RESPONSE_BYTES      = MAX_ORDINARY_RESPONSE_BYTES.to_i
    IDENTITY_RESPONSE_PATHS = {"/v1/ships/inspect", "/v1/radio/wait"}
    ROTATION_LIMIT_PATHS    = {"/v1/owners/rotate", "/v1/relationships/close"}

    getter origin : String

    def initialize(@origin)
      Origin.validate!(origin)
    end

    def post(path : String, body : String) : String
      request("POST", path, body)
    end

    private def request(method : String, path : String,
                        body : String? = nil) : String
      uri = URI.parse("#{origin.rstrip('/')}#{path}")
      client = HTTP::Client.new(uri)
      client.connect_timeout = 5.seconds
      client.read_timeout = read_timeout(path)
      headers = HTTP::Headers{
        "Accept"              => "application/json",
        "User-Agent"          => "tinrelay/#{VERSION}",
        "X-Request-ID"        => Ids.uuid,
        "X-Tinrelay-Protocol" => PROTOCOL.to_s,
      }
      headers["Content-Type"] = "application/json" if body
      client.exec(method, uri.request_target, headers: headers, body: body) do |response|
        response_body(
          response.status_code, response.success?,
          read_body(response.body_io, response_limit(path)), response.headers, path
        )
      end
    rescue Socket::Error | IO::TimeoutError
      raise TransportUnavailable.new
    rescue error : IO::Error
      raise TransportUnavailable.new if retryable_transport_error?(error)
      raise error
    ensure
      client.try(&.close)
    end

    private def retryable_transport_error?(error : IO::Error) : Bool
      case os_error = error.os_error
      when Errno
        os_error == Errno::ETIMEDOUT
      when WinError
        os_error == WinError::WSAETIMEDOUT
      else
        false
      end
    end

    private def read_timeout(path : String) : Time::Span
      return 115.seconds if path == "/v1/radio/wait"
      35.seconds
    end

    private def response_limit(path : String) : Int64
      return MAX_IDENTITY_RESPONSE_BYTES if IDENTITY_RESPONSE_PATHS.includes?(path)
      MAX_RESPONSE_BYTES.to_i64
    end

    private def read_body(io : IO, limit : Int64) : String
      buffer = IO::Memory.new
      count = IO.copy(io, buffer, limit + 1)
      if count > limit
        raise Error.new("relay response exceeds #{limit} bytes")
      end
      buffer.to_s
    end

    private def response_body(status_code : Int32, success : Bool,
                              body : String, headers : HTTP::Headers,
                              path : String) : String
      return body if success
      if status_code == 426
        evidence = protocol_mismatch_evidence(body)
        raise ProtocolMismatch.new(
          evidence.client_protocol, evidence.supported_min,
          evidence.supported_max, evidence.relation
        )
      end
      if status_code == 503
        valid, back_at = maintenance_evidence(body)
        raise Maintenance.new(back_at) if valid
      end
      if status_code == 429 && path == "/v1/join"
        retry_after = registration_limit_evidence(body, headers)
        raise RegistrationLimited.new(retry_after) if retry_after
      end
      if status_code == 429 && path == "/v1/transmissions"
        retry_after = transmission_limit_evidence(body, headers)
        raise TransmissionLimited.new(retry_after) if retry_after
      end
      if status_code == 403 && path == "/v1/join" && registration_forbidden?(body)
        raise RegistrationUnavailable.new
      end
      if status_code == 429 && ROTATION_LIMIT_PATHS.includes?(path)
        retry_after = rotation_limit_evidence(body, headers)
        raise RotationLimited.new(retry_after) if retry_after
      end
      case status_code
      when 400      then raise Invalid.new("relay rejected an invalid request")
      when 401, 403 then raise Unauthorized.new("relay authentication failed")
      when 404      then raise NotFound.new("relay object is unavailable")
      when 409
        raise RadioWaitReconnect.new if path == "/v1/radio/wait"
        raise Conflict.new("relay reported a state conflict")
      when 410 then raise Expired.new("relay object has expired")
      when 429 then raise Unavailable.new("relay rate limit reached")
      when 503 then raise Unavailable.new("relay is unavailable")
      else          raise Error.new("relay returned HTTP #{status_code}")
      end
    end

    private def registration_forbidden?(body : String) : Bool
      object = JSON.parse(body).as_h?
      return false unless object
      object["error"]?.try(&.as_s?) == "registration_forbidden"
    rescue JSON::ParseException
      false
    end

    private def registration_limit_evidence(body : String,
                                            headers : HTTP::Headers) : Int64?
      retry_after = headers["Retry-After"]?.try(&.to_i64?)
      return nil unless retry_after && retry_after > 0
      object = JSON.parse(body).as_h?
      return nil unless object
      return nil unless object["error"]?.try(&.as_s?) == "registration_limited"
      retry_after
    rescue JSON::ParseException
      nil
    end

    private def transmission_limit_evidence(body : String,
                                            headers : HTTP::Headers) : Int64?
      retry_after = headers["Retry-After"]?.try(&.to_i64?)
      return nil unless retry_after && retry_after > 0
      object = JSON.parse(body).as_h?
      return nil unless object
      return nil unless object["error"]?.try(&.as_s?) == "transmission_limited"
      retry_after
    rescue JSON::ParseException
      nil
    end

    private def rotation_limit_evidence(body : String,
                                        headers : HTTP::Headers) : Int64?
      header = headers["Retry-After"]?.try(&.to_i64?)
      return nil unless header && header > 0
      evidence = RotationLimitEvidence.from_json(body)
      return nil unless evidence.error == "rotation_limited"
      return nil unless evidence.retry_after_seconds == header
      header
    rescue JSON::ParseException | JSON::SerializableError
      nil
    end

    private def protocol_mismatch_evidence(body : String) : ProtocolMismatchEvidence
      evidence = ProtocolMismatchEvidence.from_json(body)
      relation = if evidence.client_protocol < evidence.supported_min
                   "older"
                 elsif evidence.client_protocol > evidence.supported_max
                   "newer"
                 else
                   "equal"
                 end
      unless evidence.error == "protocol_incompatible" &&
             evidence.supported_min <= evidence.supported_max &&
             evidence.relation == relation && relation != "equal"
        raise Error.new("relay returned invalid protocol-mismatch evidence")
      end
      evidence
    rescue JSON::ParseException | JSON::SerializableError
      raise Error.new("relay returned invalid protocol-mismatch evidence")
    end

    private def maintenance_evidence(body : String) : Tuple(Bool, Time?)
      evidence = MaintenanceEvidence.from_json(body)
      unless evidence.error == "maintenance" && evidence.back_at_present?
        return {false, nil}
      end
      back_at = evidence.back_at.try { |value| Time.parse_rfc3339(value) }
      {true, back_at}
    rescue JSON::ParseException | JSON::SerializableError | Time::Format::Error
      {false, nil}
    end
  end

  class Client
    MAX_PLAINTEXT_BYTES = 16 * 1024

    getter keyring : Keyring
    getter remote : Remote

    def initialize(@keyring, remote : Remote? = nil)
      @remote = remote || Remote.new(keyring.data.server)
      mutate_keyring { keyring.prune_retired_radios! }
    end

    def self.join(keyring_path : String, server : String, ship : String,
                  owner_path : String? = nil) : Client
      owner_file = owner_path || "#{keyring_path}.owner"
      prepared = nil.as(JoinKeyring?)
      begin
        prepared = Keyring.prepare_join(
          keyring_path, server, ship, owner_file
        )
        keyring = prepared.keyring
        existing = prepared.cleanup_token.nil?
        client = new(keyring)
        if existing && claim_committed?(client, keyring)
          keyring.finish_join
          return client
        end
        claim = ShipClaim.new(
          ship, keyring.data.owner_public_key, keyring.data.radio!.certificate
        )
        begin
          client.remote.post("/v1/join", claim.to_json)
        rescue ex : Conflict
          if existing && claim_committed?(client, keyring)
            keyring.finish_join
            return client
          end
          raise ex
        end
        keyring.finish_join
        client
      rescue ex : Invalid | NotFound | Conflict | Expired
        if candidate = prepared
          candidate.cleanup_token.try do |token|
            candidate.keyring.abandon_join(token)
          end
        end
        raise ex
      rescue ex : ProtocolMismatch | RegistrationLimited | RegistrationUnavailable
        if candidate = prepared
          candidate.cleanup_token.try do |token|
            candidate.keyring.abandon_join(token)
          end
        end
        raise ex
      end
    end

    private def self.claim_committed?(client : Client, keyring : Keyring) : Bool
      document = JSON.parse(client.who(keyring.data.ship))
      return false unless document["ship"].as_s == keyring.data.ship
      return false unless document["state"].as_s == "active"
      owner = document["owner_keys"].as_a.find do |item|
        item["generation"].as_i == 1 && item["state"].as_s == "active"
      end
      radio = document["radio_keys"].as_a.find do |item|
        item["generation"].as_i == 1 && item["state"].as_s == "active"
      end
      return false unless owner && radio
      certificate = ShipRadioCertificate.new(
        document["ship"].as_s, radio["generation"].as_i.to_i,
        radio["signing_public_key"].as_s, radio["encryption_public_key"].as_s,
        radio["issued_at"].as_i64, radio["owner_generation"].as_i.to_i,
        radio["owner_signature"].as_s
      )
      expected = keyring.data.radio!(1).certificate
      unless owner["public_key"].as_s == keyring.data.owner_public_key &&
             certificate.to_json == expected.to_json &&
             Crypto.verify(
               certificate.unsigned_bytes,
               Crypto.unb64(certificate.owner_signature),
               Crypto.unb64(keyring.data.owner_public_key)
             )
        raise Unauthorized.new("remote claim does not match the provisional ship identity")
      end
      true
    rescue Unauthorized | NotFound | Unavailable
      false
    end

    def send(recipient : String, body : String, from_label : String? = nil,
             expires_in : Int64 = FALLBACK_LIFETIME_SECONDS.to_i64,
             outbox : Outbox? = nil,
             observer : OutgoingObserver? = nil) : SignedRelayEnvelope
      reconcile_radio_if_pending!
      to_label, recipient_ship = Names.coordinate!(recipient)
      from_label.try { |label| Names.label!(label) }
      raise Invalid.new("transmission body is empty") if body.empty?
      transmission_id = Ids.uuid
      created_at = Time.utc.to_unix
      radio = keyring.data.radio!
      contact = unless recipient_ship == keyring.data.ship
        pinned = keyring.data.contact!(recipient_ship)
        raise Unauthorized.new("contact is locally blocked") if pinned.blocked?
        pinned
      end
      recipient_certificate = contact.try(&.radio_certificate) || radio.certificate

      # Sign the plaintext first: SignedTransmission preserves ship-level provenance
      # of the exact words after relay ciphertext and receive keys are gone.
      transmission = SignedTransmission.new(
        transmission_id, keyring.data.ship, radio.generation,
        recipient_ship, recipient_certificate.generation, created_at,
        to_label, body, from_label
      )
      transmission.signature = Crypto.b64(
        Crypto.sign(
          transmission.signing_bytes, Crypto.unb64(radio.signing.secret_key)
        )
      )
      plaintext = transmission.to_json.to_slice
      if plaintext.size > MAX_PLAINTEXT_BYTES
        raise Invalid.new("transmission exceeds #{MAX_PLAINTEXT_BYTES} UTF-8 bytes")
      end
      ciphertext = Crypto.seal(
        plaintext, Crypto.unb64(recipient_certificate.encryption_public_key)
      )
      # Sign again after sealing: SignedRelayEnvelope authenticates the radio emission
      # so the repeater and recipient reject route or ciphertext changes before opening it.
      envelope = SignedRelayEnvelope.new(
        transmission_id, keyring.data.ship, radio.generation,
        recipient_ship, recipient_certificate.generation, created_at,
        created_at + expires_in, Crypto.b64(ciphertext)
      )
      envelope.signature = Crypto.b64(
        Crypto.sign(envelope.signing_bytes, Crypto.unb64(radio.signing.secret_key))
      )
      submit(envelope, outbox || Outbox.new("#{keyring.path}.outbox"))
      observer.try(&.notify(transmission))
      envelope
    end

    def retry(outbox : Outbox, transmission_id : String) : SignedRelayEnvelope
      envelope, encoded = outbox.read(transmission_id)
      unless envelope.sender_ship == keyring.data.ship
        raise Unauthorized.new("outbox transmission belongs to another local ship")
      end
      submit_encoded(envelope, encoded, outbox)
      envelope
    end

    def hail(recipient_ship : String,
             expires_in : Int64 = HAIL_LIFETIME_SECONDS.to_i64) : Hail
      reconcile_radio_if_pending!
      recipient = Names.ship!(recipient_ship)
      raise Invalid.new("a ship cannot hail itself") if recipient == keyring.data.ship
      radio = keyring.data.radio!
      created_at = Time.utc.to_unix
      hail = Hail.new(
        Ids.uuid, keyring.data.ship, radio.generation,
        recipient, created_at, created_at + expires_in
      )
      hail.signature = Crypto.b64(
        Crypto.sign(hail.signing_bytes, Crypto.unb64(radio.signing.secret_key))
      )
      submit_hail(hail)
      hail
    end

    def radio_wait(spool : Spool,
                   hold_seconds : Int32 = RADIO_WAIT_HOLD_SECONDS) : RadioEvent
      spool.with_radio_lock do
        radio_wait_unlocked(spool, hold_seconds)
      end
    end

    def radio_collect(spool : Spool,
                      hold_seconds : Int32 = RADIO_WAIT_HOLD_SECONDS) : RadioEvent
      spool.with_radio_lock do
        radio_collect_unlocked(spool, hold_seconds)
      end
    end

    def radio_poll(spool : Spool) : RadioEvent?
      spool.with_radio_lock do
        if event = local_radio_event(spool)
          event
        else
          reconcile_radio_if_pending!
          radio_attempt(spool, 0)
        end
      end
    end

    private def radio_wait_unlocked(spool : Spool,
                                    hold_seconds : Int32) : RadioEvent
      if event = local_radio_event(spool)
        return event
      end
      reconcile_radio_if_pending!
      loop do
        if event = radio_attempt(spool, hold_seconds)
          return event
        end
      end
    end

    private def radio_collect_unlocked(spool : Spool,
                                       hold_seconds : Int32) : RadioEvent
      reconcile_radio_if_pending!
      loop do
        if event = radio_attempt(spool, hold_seconds)
          return event
        end
      end
    end

    private def local_radio_event(spool : Spool) : RadioEvent?
      return unless record = spool.next_unrouted
      # A durable local pointer is useful without the repeater. If its cleanup
      # ack was lost, the bounded relay copy will be acked when it reappears.
      LocalRadio.event(keyring.data.ship, record)
    end

    private def radio_attempt(spool : Spool,
                              hold_seconds : Int32) : RadioEvent?
      refresh_keyring!
      known = keyring.data.contacts.to_h do |contact|
        {contact.ship, contact.radio_certificate.generation}
      end
      placeholder = RadioAuth.new(
        keyring.data.ship, keyring.data.active_radio_generation, 0_i64
      )
      request = RadioWaitRequest.new(
        hold_seconds, placeholder, known
      )
      request.auth = radio_auth("radio.wait", request.payload)
      response = RadioWaitResponse.from_json(
        remote.post("/v1/radio/wait", request.to_json)
      )
      unless response.contact_updates.empty?
        mutate_keyring do
          response.contact_updates.each do |update|
            contact = keyring.data.contact!(update.ship)
            apply_contact_update!(contact, update)
          end
        end
        response.contact_updates.each do |update|
          acknowledge_retune(update.ship, update.to_generation)
        end
        return
      end
      if hail = response.hail
        record = mutate_keyring { receive_hail(hail, spool) }
        record ? acknowledge_local_record(record) : acknowledge_hail(hail.hail.hail_id)
        return unless record && !record.routed
        return LocalRadio.event(keyring.data.ship, record)
      end
      if envelope = response.envelope
        record = begin
          receive_with_latest_keyring(envelope, spool)
        rescue Conflict
          spool.store_rejection(envelope, "transmission_id_conflict")
        rescue Invalid | Unauthorized | NotFound
          spool.store_rejection(envelope, "unusable_envelope")
        end
        record ? acknowledge_local_record(record) : acknowledge(envelope.transmission_id)
        return unless record && !record.routed
        return LocalRadio.event(keyring.data.ship, record)
      end
    end

    # Local evidence is already the durable recovery boundary. Relay cleanup is
    # best effort here so an unavailable repeater cannot hide an unrouted pointer.
    private def acknowledge_local_record(record : SpoolRecord) : Nil
      case record
      when TransmissionSpoolRecord, RejectedTransmissionSpoolRecord
        acknowledge(record.relay_transmission_id)
      when HailSpoolRecord
        acknowledge_hail(record.hail_id)
      end
    rescue Unavailable
    end

    def acknowledge(transmission_id : String) : Nil
      reconcile_radio_if_pending!
      request = TransmissionAck.new(
        transmission_id, radio_auth("transmission.ack", Canonical.fields(transmission_id))
      )
      remote.post("/v1/transmissions/ack", request.to_json)
    end

    def acknowledge_hail(hail_id : String) : Nil
      reconcile_radio_if_pending!
      request = HailAck.new(
        hail_id, radio_auth("hail.ack", Canonical.fields(hail_id))
      )
      remote.post("/v1/hails/ack", request.to_json)
    end

    def acknowledge_retune(owner_ship : String, generation : Int32) : Nil
      payload = Canonical.fields(owner_ship, generation.to_s)
      request = RetuneAck.new(
        owner_ship, generation,
        radio_auth("relationship.retune.ack", payload)
      )
      remote.post("/v1/relationships/retune/ack", request.to_json)
    end

    def who(ship_or_coordinate : String) : String
      reconcile_radio_if_pending!
      ship = if ship_or_coordinate.includes?('@')
               Names.coordinate!(ship_or_coordinate)[1]
             else
               Names.ship!(ship_or_coordinate)
             end
      document = inspect_document(ship)
      mutate_keyring do
        if contact = keyring.data.contacts.find { |item| item.ship == ship }
          update_contact_from_document!(contact, document)
        end
      end
      document.to_json
    end

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
        owner_auth("relationship.close", Bytes.empty)
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

    def allow_contact(local_hail_id : String, spool : Spool) : ShipContact
      record = spool.get(local_hail_id).as?(HailSpoolRecord) ||
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
      payload = Canonical.fields(peer, record.hail_id)
      request = RelationshipAllow.new(
        peer, record.hail_id, radio_auth("relationship.allow", payload)
      )
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
          pending = StoredKeyPair.new(
            Crypto.b64(keys.public_key), Crypto.b64(keys.secret_key)
          )
          owner.pending_generation = generation
          owner.pending_key = pending
        end
        bytes = Canonical.fields(
          "tinrelay-owner-rotation-v1", keyring.data.ship,
          generation.to_s, pending.public_key
        )
        signature = Crypto.b64(
          Crypto.sign(bytes, Crypto.unb64(owner.key.secret_key))
        )
        {generation, pending, signature}
      end
      new_public = pending_key.public_key
      provisional = OwnerRotation.new(
        new_generation, new_public, prior_signature,
        owner_auth("owner.rotate", Bytes.empty)
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
      provisional = ShipChange.new(operation, owner_auth("ship.change", Bytes.empty))
      provisional.auth = owner_auth("ship.change", provisional.payload)
      remote.post("/v1/ships/change", provisional.to_json)
    end

    private def receive_with_latest_keyring(envelope : SignedRelayEnvelope,
                                            spool : Spool) : SpoolRecord?
      document = if envelope.sender_ship == keyring.data.ship
                   inspect_receive_identity(envelope.sender_ship)
                 end
      loop do
        begin
          return mutate_keyring { receive(envelope, spool, document) }
        rescue IdentityDocumentRequired
          document = inspect_receive_identity(envelope.sender_ship)
        end
      end
    end

    private def inspect_receive_identity(ship : String) : JSON::Any
      prior = keyring.data.to_json
      inspect_document(ship)
    rescue ex : Unauthorized | Unavailable
      refresh_keyring!
      raise ex if keyring.data.to_json == prior
      inspect_document(ship)
    end

    private def receive(envelope : SignedRelayEnvelope, spool : Spool,
                        document : JSON::Any?) : SpoolRecord?
      unless envelope.recipient_ship == keyring.data.ship
        raise Unauthorized.new("radio returned a transmission for another ship")
      end
      recipient = keyring.data.radio!(envelope.recipient_encryption_generation)
      contact = keyring.data.contacts.find { |item| item.ship == envelope.sender_ship }
      self_transmission = envelope.sender_ship == keyring.data.ship
      certificate, owner_generation, owner_public, owner_chain = receive_identity(
        envelope,
        contact,
        self_transmission,
        document
      )
      unless Crypto.verify(
               envelope.signing_bytes, Crypto.unb64(envelope.signature),
               Crypto.unb64(certificate.signing_public_key)
             )
        raise Unauthorized.new("sender signature is invalid")
      end
      return nil if contact.try(&.blocked?)
      plaintext = Crypto.open(
        Crypto.unb64(envelope.ciphertext),
        Crypto.unb64(recipient.encryption.public_key),
        Crypto.unb64(recipient.encryption.secret_key)
      )
      transmission = SignedTransmission.from_json(String.new(plaintext))
      validate_signed_transmission!(transmission, envelope, certificate)
      raise Invalid.new("received plaintext exceeds limit") if plaintext.size > MAX_PLAINTEXT_BYTES
      unless self_transmission
        update_pinned_sender!(
          envelope, certificate, owner_generation, owner_public, owner_chain
        )
      end
      record = spool.store_transmission(
        envelope, transmission, certificate, owner_public,
        owner_chain
      )
      record
    rescue ex : JSON::ParseException
      raise Invalid.new("decrypted transmission is invalid")
    end

    private def receive_identity(
      envelope : SignedRelayEnvelope,
      contact : ShipContact?,
      self_transmission : Bool,
      document : JSON::Any?,
    )
      if self_transmission
        receive_self_identity(
          envelope,
          document || raise(IdentityDocumentRequired.new)
        )
      elsif contact &&
            contact.radio_certificate.generation == envelope.sender_signing_generation
        {
          contact.radio_certificate,
          contact.owner_generation,
          contact.owner_public_key,
          contact.owner_chain,
        }
      elsif contact
        document ||= raise IdentityDocumentRequired.new
        certificate, owner_generation, owner_public = trusted_radio(
          document,
          envelope.sender_signing_generation,
          contact
        )
        {
          certificate,
          owner_generation,
          owner_public,
          owner_chain_evidence(document, contact, owner_generation),
        }
      else
        raise Unauthorized.new("sender ship is not pinned locally")
      end
    end

    private def receive_self_identity(envelope : SignedRelayEnvelope,
                                      document : JSON::Any)
      # Same-ship receive uses the exact local certificate as its trust anchor.
      # Registry evidence supplies the public owner key for durable verification,
      # but cannot substitute a different radio or create a self-contact.
      local_certificate = keyring.data.radio!(
        envelope.sender_signing_generation
      ).certificate
      certificate, owner_generation, owner_public = trusted_radio(
        document,
        envelope.sender_signing_generation,
        nil
      )
      unless certificate.to_json == local_certificate.to_json
        raise Unauthorized.new(
          "registry radio certificate differs from the local ship identity"
        )
      end
      {
        local_certificate,
        owner_generation,
        owner_public,
        owner_chain_evidence(document, nil, owner_generation),
      }
    end

    private def validate_signed_transmission!(
      transmission : SignedTransmission,
      envelope : SignedRelayEnvelope,
      certificate : ShipRadioCertificate,
    ) : Nil
      unless transmission.object_version == 1 && transmission.protocol == PROTOCOL
        raise Invalid.new("unsupported signed transmission version")
      end
      Names.ship!(transmission.sender_ship)
      Names.ship!(transmission.recipient_ship)
      Names.attention!(transmission.to_label)
      transmission.from_label.try { |label| Names.label!(label) }
      raise Invalid.new("received body is empty") if transmission.body.empty?
      unless Crypto.verify(
               transmission.signing_bytes,
               Crypto.unb64(transmission.signature, "signed transmission signature"),
               Crypto.unb64(certificate.signing_public_key)
             )
        raise Unauthorized.new("signed transmission signature is invalid")
      end
      unless transmission.transmission_id == envelope.transmission_id &&
             transmission.sender_ship == envelope.sender_ship &&
             transmission.sender_signing_generation == envelope.sender_signing_generation &&
             transmission.recipient_ship == envelope.recipient_ship &&
             transmission.recipient_encryption_generation ==
               envelope.recipient_encryption_generation &&
             transmission.created_at == envelope.created_at
        raise Unauthorized.new("signed transmission and relay envelope facts differ")
      end
    end

    private def receive_hail(delivery : HailDelivery, spool : Spool) : SpoolRecord?
      hail = delivery.hail
      unless hail.recipient_ship == keyring.data.ship
        raise Unauthorized.new("radio returned a hail for another ship")
      end
      certificate = delivery.sender_radio_certificate
      unless certificate.ship == hail.sender_ship
        raise Unauthorized.new("hail certificate belongs to another ship")
      end
      unless certificate.generation == hail.sender_signing_generation
        raise Unauthorized.new("hail radio generation and certificate differ")
      end
      contact = keyring.data.contacts.find { |item| item.ship == hail.sender_ship }
      contact_state = "stranger"
      owner_chain = [] of OwnerKeyLink
      if contact
        owner_chain = verify_owner_chain(contact, delivery.owner_chain)
        verified = if certificate.generation < contact.radio_certificate.generation &&
                      delivery.radio_chain.empty? && delivery.owner_chain.empty?
                     unless certificate.owner_generation == contact.owner_generation &&
                            Crypto.verify(
                              certificate.unsigned_bytes,
                              Crypto.unb64(certificate.owner_signature),
                              Crypto.unb64(contact.owner_public_key)
                            )
                       raise Unauthorized.new(
                         "older hail certificate is not pinned-owner-authorized"
                       )
                     end
                     certificate
                   else
                     verify_radio_chain(
                       contact, delivery.radio_chain, certificate, owner_chain
                     )
                   end
        contact_state = "known_prior_contact"
        return nil if contact.blocked?
        if verified.generation > contact.radio_certificate.generation
          contact.owner_chain = owner_chain
          current_owner = owner_chain.last
          contact.owner_generation = current_owner.generation
          contact.owner_public_key = current_owner.public_key
          contact.radio_certificate = verified
        end
      else
        unless delivery.owner_chain.empty?
          raise Unauthorized.new("stranger hail has unexpected owner history")
        end
        owner_public = Crypto.unb64(
          delivery.sender_owner_public_key, "hail sender owner public key"
        )
        unless Crypto.verify(
                 certificate.unsigned_bytes,
                 Crypto.unb64(certificate.owner_signature), owner_public
               )
          raise Unauthorized.new("hail radio certificate is not owner-authorized")
        end
        owner_chain << OwnerKeyLink.new(
          certificate.owner_generation, delivery.sender_owner_public_key
        )
      end
      unless Crypto.verify(
               hail.signing_bytes, Crypto.unb64(hail.signature),
               Crypto.unb64(certificate.signing_public_key)
             )
        raise Unauthorized.new("hail signature is invalid")
      end
      spool.store_hail(hail, certificate, owner_chain, contact_state)
    end

    private def update_pinned_sender!(envelope : SignedRelayEnvelope,
                                      certificate : ShipRadioCertificate,
                                      owner_generation : Int32,
                                      owner_public : String,
                                      owner_chain : Array(OwnerKeyLink)) : Bool
      contact = keyring.data.contact!(envelope.sender_ship)
      if certificate.generation == contact.radio_certificate.generation &&
         certificate.to_json != contact.radio_certificate.to_json
        raise Unauthorized.new("pinned sender radio changed within one generation")
      end
      return false unless certificate.generation > contact.radio_certificate.generation
      contact.owner_chain = owner_chain
      contact.owner_generation = owner_generation
      contact.owner_public_key = owner_public
      contact.radio_certificate = certificate
      true
    end

    private def verify_hail_record!(record : HailSpoolRecord,
                                    prior : ShipContact?) : Nil
      hail = record.hail
      certificate = record.sender_radio_certificate
      raise Invalid.new("unsupported hail protocol") unless hail.protocol == PROTOCOL
      unless certificate.ship == hail.sender_ship
        raise Unauthorized.new("hail certificate names another ship")
      end
      unless certificate.generation == hail.sender_signing_generation
        raise Unauthorized.new("hail certificate generation differs")
      end
      owners = record.sender_owner_chain
      owner = owners.find { |link| link.generation == certificate.owner_generation } ||
              raise Unauthorized.new("hail owner key is absent")
      owners.each_cons(2) do |pair|
        previous, current = pair
        unless current.generation == previous.generation + 1
          raise Unauthorized.new("hail owner continuity skips a generation")
        end
        signature = current.authorization_signature ||
                    raise Unauthorized.new("hail owner continuity lacks an authorization")
        bytes = Canonical.fields(
          "tinrelay-owner-rotation-v1", hail.sender_ship,
          current.generation.to_s, current.public_key
        )
        unless Crypto.verify(bytes, Crypto.unb64(signature), Crypto.unb64(previous.public_key))
          raise Unauthorized.new("hail owner continuity is invalid")
        end
      end
      if prior
        observed_anchor = owners.first(prior.owner_chain.size).map(&.to_json)
        unless observed_anchor == prior.owner_chain.map(&.to_json)
          raise Unauthorized.new("hail owner identity differs from the local pin")
        end
      end
      unless Crypto.verify(
               certificate.unsigned_bytes,
               Crypto.unb64(certificate.owner_signature),
               Crypto.unb64(owner.public_key)
             )
        raise Unauthorized.new("hail radio certificate is not owner-authorized")
      end
      unless Crypto.verify(
               hail.signing_bytes, Crypto.unb64(hail.signature),
               Crypto.unb64(certificate.signing_public_key)
             )
        raise Unauthorized.new("hail signature is invalid")
      end
    end

    private def apply_contact_update!(contact : ShipContact,
                                      update : ContactUpdate) : Bool
      unless update.ship == contact.ship
        raise Unauthorized.new("contact update names another ship")
      end
      if contact.radio_certificate.generation >= update.to_generation
        if contact.radio_certificate.generation == update.to_generation
          delivered = update.chain.last?.try(&.certificate)
          unless delivered && delivered.to_json == contact.radio_certificate.to_json
            raise Unauthorized.new("contact update conflicts with the current radio identity")
          end
        end
        return false
      end
      owner_links = update.owner_chain.select do |link|
        link.generation > contact.owner_generation
      end
      radio_links = update.chain.select do |link|
        link.certificate.generation > contact.radio_certificate.generation
      end
      owners = verify_owner_chain(contact, owner_links)
      certificate = verify_radio_chain(
        contact, radio_links, update.chain.last.certificate, owners
      )
      changed = owners != contact.owner_chain ||
                certificate.to_json != contact.radio_certificate.to_json
      return false unless changed
      current_owner = owners.last
      contact.owner_chain = owners
      contact.owner_generation = current_owner.generation
      contact.owner_public_key = current_owner.public_key
      contact.radio_certificate = certificate
      true
    end

    private def verify_owner_chain(contact : ShipContact,
                                   links : Array(OwnerKeyLink)) : Array(OwnerKeyLink)
      owners = contact.owner_chain.dup
      current = owners.last
      links.each do |link|
        unless link.generation == current.generation + 1
          raise Unauthorized.new("owner continuity chain skips a generation")
        end
        signature = link.authorization_signature ||
                    raise Unauthorized.new("owner continuity chain lacks an authorization")
        bytes = Canonical.fields(
          "tinrelay-owner-rotation-v1", contact.ship,
          link.generation.to_s, link.public_key
        )
        unless Crypto.verify(
                 bytes, Crypto.unb64(signature),
                 Crypto.unb64(current.public_key)
               )
          raise Unauthorized.new("owner continuity chain is invalid")
        end
        owners << link
        current = link
      end
      owners
    end

    private def verify_radio_chain(
      contact : ShipContact,
      links : Array(RadioCertificateLink),
      final_certificate : ShipRadioCertificate,
      owners : Array(OwnerKeyLink) = contact.owner_chain,
    ) : ShipRadioCertificate
      current = contact.radio_certificate
      links.each do |link|
        certificate = link.certificate
        unless certificate.ship == contact.ship
          raise Unauthorized.new("radio continuity chain names another ship")
        end
        unless certificate.generation == current.generation + 1
          raise Unauthorized.new("radio continuity chain skips a generation")
        end
        if certificate.owner_generation < current.owner_generation
          raise Unauthorized.new("radio continuity chain moves owner generation backward")
        end
        owner = owners.find { |item| item.generation == certificate.owner_generation } ||
                raise Unauthorized.new("radio continuity chain lacks its owner key")
        unless Crypto.verify(
                 certificate.unsigned_bytes,
                 Crypto.unb64(certificate.owner_signature),
                 Crypto.unb64(owner.public_key)
               )
          raise Unauthorized.new("radio continuity certificate is not owner-authorized")
        end
        prior_signature = link.prior_radio_signature ||
                          raise Unauthorized.new("radio continuity chain lacks a prior signature")
        unless Crypto.verify(
                 certificate.unsigned_bytes, Crypto.unb64(prior_signature),
                 Crypto.unb64(current.signing_public_key)
               )
          raise Unauthorized.new("radio continuity chain lacks prior-radio authorization")
        end
        current = certificate
      end
      unless current.to_json == final_certificate.to_json
        raise Unauthorized.new("radio continuity chain does not reach the delivered certificate")
      end
      current
    end

    private def update_contact_from_document!(contact : ShipContact,
                                              document : JSON::Any) : Bool
      active = document["radio_keys"].as_a.find { |item| item["state"].as_s == "active" } ||
               raise Unavailable.new("pinned ship has no active radio")
      certificate, owner_generation, owner_public = trusted_radio(
        document, active["generation"].as_i.to_i, contact
      )
      owner_chain = owner_chain_evidence(document, contact, owner_generation)
      changed = contact.owner_generation != owner_generation ||
                contact.owner_public_key != owner_public ||
                contact.radio_certificate.to_json != certificate.to_json
      return false unless changed
      contact.owner_chain = owner_chain
      contact.owner_generation = owner_generation
      contact.owner_public_key = owner_public
      contact.radio_certificate = certificate
      true
    end

    private def trusted_radio(document : JSON::Any, generation : Int32,
                              contact : ShipContact?) : Tuple(ShipRadioCertificate, Int32, String)
      ship = document["ship"].as_s
      radio = document["radio_keys"].as_a.find { |item| item["generation"].as_i == generation } ||
              raise Unauthorized.new("sender radio key is absent from registry")
      owner_generation = radio["owner_generation"].as_i.to_i
      owner_public = trusted_owner(document, owner_generation, contact)
      certificate = ShipRadioCertificate.new(
        ship, generation, radio["signing_public_key"].as_s,
        radio["encryption_public_key"].as_s, radio["issued_at"].as_i64,
        owner_generation, radio["owner_signature"].as_s
      )
      unless Crypto.verify(
               certificate.unsigned_bytes,
               Crypto.unb64(certificate.owner_signature),
               Crypto.unb64(owner_public)
             )
        raise Unauthorized.new("ship radio certificate is invalid")
      end
      {certificate, owner_generation, owner_public}
    end

    private def trusted_owner(document : JSON::Any, target : Int32,
                              contact : ShipContact?) : String
      owners = document["owner_keys"].as_a.sort_by { |item| item["generation"].as_i }
      if contact
        generation = contact.owner_generation
        public_key = contact.owner_public_key
        pinned = owners.find { |item| item["generation"].as_i == generation } ||
                 raise Unauthorized.new("pinned owner key disappeared from registry")
        unless pinned["public_key"].as_s == public_key
          raise Unauthorized.new("pinned owner key changed")
        end
      else
        owner = owners.find { |item| item["generation"].as_i == target } ||
                raise Unauthorized.new("ship owner key is absent from registry")
        return owner["public_key"].as_s
      end
      while generation < target
        next_owner = owners.find { |item| item["generation"].as_i == generation + 1 } ||
                     raise Unauthorized.new("owner rotation chain is incomplete")
        next_public = next_owner["public_key"].as_s
        signature = next_owner["authorization_signature"]?.try(&.as_s?) ||
                    raise Unauthorized.new("owner rotation chain lacks a signature")
        bytes = Canonical.fields(
          "tinrelay-owner-rotation-v1", document["ship"].as_s,
          (generation + 1).to_s, next_public
        )
        unless Crypto.verify(bytes, Crypto.unb64(signature), Crypto.unb64(public_key))
          raise Unauthorized.new("owner rotation chain is invalid")
        end
        generation += 1
        public_key = next_public
      end
      unless generation == target
        raise Unauthorized.new("registry returned an older owner generation")
      end
      public_key
    end

    private def owner_chain_evidence(document : JSON::Any,
                                     contact : ShipContact?,
                                     target : Int32) : Array(OwnerKeyLink)
      start = contact.try(&.owner_generation) || target
      observed = document["owner_keys"].as_a
        .select { |item| item["generation"].as_i.in?(start..target) }
        .sort_by { |item| item["generation"].as_i }
        .map_with_index do |item, index|
          OwnerKeyLink.new(
            item["generation"].as_i.to_i,
            item["public_key"].as_s,
            index == 0 ? nil : item["authorization_signature"].as_s
          )
        end
      return observed unless contact
      contact.owner_chain + observed[1..]
    end

    private def inspect_document(target : String,
                                 all_local_radios : Bool = false) : JSON::Any
      target = Names.ship!(target)
      radios = if all_local_radios
                 candidates = keyring.data.radios.dup
                 candidates << keyring.data.pending_radio.not_nil! if keyring.data.pending_radio
                 candidates.sort_by(&.generation).reverse
               else
                 [keyring.data.radio!]
               end
      last_auth_error = nil.as(Error?)
      radios.each do |radio|
        payload = Canonical.fields(target)
        request = ShipInspection.new(
          target, radio_auth("ship.inspect", payload, radio: radio)
        )
        begin
          return JSON.parse(remote.post("/v1/ships/inspect", request.to_json))
        rescue ex : Unauthorized | Unavailable
          last_auth_error = ex
        end
      end
      raise(last_auth_error || Unauthorized.new("no local radio can inspect the registry"))
    end

    private def submit(envelope : SignedRelayEnvelope, outbox : Outbox) : Nil
      encoded = outbox.store(envelope)
      submit_encoded(envelope, encoded, outbox)
    end

    private def submit_encoded(envelope : SignedRelayEnvelope, encoded : String,
                               outbox : Outbox) : Nil
      response_body = begin
        remote.post("/v1/transmissions", encoded)
      rescue ex : Invalid | Unauthorized | NotFound | Conflict | Expired | ProtocolMismatch
        begin
          outbox.delete(envelope.transmission_id)
        rescue cleanup : IO::Error
          raise Error.new(
            "repeater rejected the transmission, but its local outbox envelope " +
            "could not be removed: #{cleanup.message}"
          )
        end
        raise ex
      rescue ex : TransmissionLimited
        raise TransmissionLimited.new(
          ex.retry_after_seconds, envelope.transmission_id, envelope.sender_ship
        )
      rescue ex : Error | IO::Error
        raise AcceptanceUnknown.new(envelope.transmission_id, envelope.sender_ship, ex.message)
      end
      accepted = begin
        JSON.parse(response_body)["state"].as_s == "accepted"
      rescue
        false
      end
      unless accepted
        raise AcceptanceUnknown.new(
          envelope.transmission_id, envelope.sender_ship,
          "repeater returned invalid acceptance evidence"
        )
      end
      begin
        outbox.delete(envelope.transmission_id)
      rescue ex : IO::Error
        raise Error.new(
          "repeater accepted transmission #{envelope.transmission_id}, but its local " +
          "outbox envelope could not be removed: #{ex.message}"
        )
      end
    end

    private def submit_hail(hail : Hail) : Nil
      response_body = begin
        remote.post("/v1/hails", hail.to_json)
      rescue ex : Invalid | Unauthorized | Conflict | Expired | ProtocolMismatch
        raise ex
      rescue ex : Error | IO::Error
        raise HailAcceptanceUnknown.new(hail.sender_ship, hail.recipient_ship, ex.message)
      end
      accepted = begin
        JSON.parse(response_body)["state"].as_s == "accepted"
      rescue
        false
      end
      unless accepted
        raise HailAcceptanceUnknown.new(
          hail.sender_ship, hail.recipient_ship,
          "repeater returned invalid acceptance evidence"
        )
      end
    end

    private def radio_auth(action : String, payload : Bytes,
                           now : Int64 = Time.utc.to_unix,
                           radio : ShipRadioIdentity? = nil) : RadioAuth
      radio = radio || keyring.data.radio!
      auth = RadioAuth.new(keyring.data.ship, radio.generation, now)
      auth.signature = Crypto.b64(
        Crypto.sign(auth.signing_bytes(action, payload), Crypto.unb64(radio.signing.secret_key))
      )
      auth
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
      signing = Crypto.signing_keypair
      encryption = Crypto.box_keypair
      certificate = ShipRadioCertificate.new(
        keyring.data.ship, generation, Crypto.b64(signing.public_key),
        Crypto.b64(encryption.public_key), Time.utc.to_unix,
        keyring.data.owner_generation
      )
      certificate.owner_signature = Crypto.b64(
        Crypto.sign(
          certificate.unsigned_bytes, Crypto.unb64(owner.key.secret_key)
        )
      )
      identity = ShipRadioIdentity.new(
        generation,
        StoredKeyPair.new(
          Crypto.b64(signing.public_key), Crypto.b64(signing.secret_key)
        ),
        StoredKeyPair.new(
          Crypto.b64(encryption.public_key), Crypto.b64(encryption.secret_key)
        ),
        certificate
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

    private def refresh_keyring! : Nil
      keyring.refresh
    end

    private def mutate_keyring(&block : -> T) : T forall T
      current = keyring
      begin
        current.mutate do |latest, _owner|
          @keyring = latest
          block.call
        end
      rescue ex
        current.refresh
        @keyring = current
        raise ex
      end
    end

    private def mutate_keyring_with_owner(&block : OwnerKeyData -> T) : T forall T
      current = keyring
      begin
        current.mutate(include_owner: true) do |latest, owner|
          @keyring = latest
          block.call(owner.not_nil!)
        end
      rescue ex
        current.refresh
        @keyring = current
        raise ex
      end
    end
  end
end
