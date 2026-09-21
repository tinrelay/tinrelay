module Tinrelay
  private class IdentityDocumentRequired < Exception
  end

  class Client
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
        acknowledge(record.transmission_id)
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
  end
end
