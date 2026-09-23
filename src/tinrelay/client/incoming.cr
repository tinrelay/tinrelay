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
      radio_collect_unlocked(spool, hold_seconds)
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
      request = RadioWaitRequest.new(
        hold_seconds, unsigned_radio_auth, known
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
      request = TransmissionAck.new(transmission_id, unsigned_radio_auth)
      request.auth = radio_auth("transmission.ack", request.payload)
      remote.post("/v1/transmissions/ack", request.to_json)
    end

    def acknowledge_hail(hail_id : String) : Nil
      reconcile_radio_if_pending!
      request = HailAck.new(hail_id, unsigned_radio_auth)
      request.auth = radio_auth("hail.ack", request.payload)
      remote.post("/v1/hails/ack", request.to_json)
    end

    def acknowledge_retune(owner_ship : String, generation : Int32) : Nil
      request = RetuneAck.new(
        owner_ship, generation, unsigned_radio_auth
      )
      request.auth = radio_auth("relationship.retune.ack", request.payload)
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
        update_pinned_sender!(envelope, certificate, owner_chain)
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
      unless certificate.same_certificate?(local_certificate)
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
      unless transmission.matches_envelope?(envelope)
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
                            certificate.owner_authorized?(
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
          contact.adopt_verified_identity!(owner_chain, verified)
        end
      else
        unless delivery.owner_chain.empty?
          raise Unauthorized.new("stranger hail has unexpected owner history")
        end
        owner_public = Crypto.unb64(
          delivery.sender_owner_public_key, "hail sender owner public key"
        )
        unless certificate.owner_authorized?(owner_public)
          raise Unauthorized.new("hail radio certificate is not owner-authorized")
        end
        owner_chain << OwnerKeyLink.new(
          certificate.owner_generation, delivery.sender_owner_public_key
        )
      end
      unless hail.signed_by?(Crypto.unb64(certificate.signing_public_key))
        raise Unauthorized.new("hail signature is invalid")
      end
      spool.store_hail(hail, certificate, owner_chain, contact_state)
    end
  end
end
