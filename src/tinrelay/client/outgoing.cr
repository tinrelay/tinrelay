module Tinrelay
  class Client
    def send(recipient : String, body : String, from_label : String? = nil,
             expires_in : Int64 = FALLBACK_LIFETIME_SECONDS.to_i64,
             outgoing : OutgoingStore? = nil,
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
      owner_public_key = authoring_owner_public_key(radio)
      record = OutgoingRecord.new(
        transmission, envelope, radio.certificate,
        OutgoingOwnerEvidence.new(radio.certificate.owner_generation, owner_public_key)
      )
      store = outgoing || OutgoingStore.new("#{keyring.path}.outgoing", keyring.data.ship)
      store.store(record)
      submit_record(record, store, initial: true, observer: observer)
      envelope
    end

    def retry(outgoing : OutgoingStore, transmission_id : String,
              observer : OutgoingObserver? = nil) : SignedRelayEnvelope
      record = outgoing.outbox(transmission_id)
      unless record.signed_transmission.sender_ship == keyring.data.ship
        raise Unauthorized.new("outbox correspondence belongs to another local ship")
      end
      unless outgoing.retryable?(record)
        raise Expired.new("outbox correspondence is no longer retryable")
      end
      submit_record(record, outgoing, initial: false, observer: observer)
      record.signed_relay_envelope
    end

    def retry(outbox : Outbox, transmission_id : String) : SignedRelayEnvelope
      envelope, encoded = outbox.read(transmission_id)
      unless envelope.sender_ship == keyring.data.ship
        raise Unauthorized.new("outbox transmission belongs to another local ship")
      end
      submit_legacy(envelope, encoded, outbox)
      envelope
    end

    def withdraw(outgoing : OutgoingStore, transmission_id : String) : OutgoingRecord
      record = outgoing.sent(transmission_id)
      unless record.signed_transmission.sender_ship == keyring.data.ship
        raise Unauthorized.new("sent correspondence belongs to another local ship")
      end
      return record if outgoing.withdrawal_requested?(transmission_id)
      reconcile_radio_if_pending!
      envelope = record.signed_relay_envelope
      placeholder = RadioAuth.new(
        keyring.data.ship, keyring.data.active_radio_generation, 0_i64
      )
      request = TransmissionWithdrawal.new(envelope.transmission_id, placeholder)
      request.auth = radio_auth("transmission.withdraw", request.payload)
      response_body = begin
        remote.post("/v1/transmissions/withdraw", request.to_json)
      rescue ex : NotFound
        raise UnsupportedFeature.new("relay does not support transmission withdrawal")
      rescue ex : Invalid | Unauthorized | Conflict | Expired | ProtocolMismatch
        raise ex
      rescue ex : TransmissionLimited
        raise WithdrawalLimited.new(
          ex.retry_after_seconds, transmission_id, envelope.sender_ship
        )
      rescue ex : Error | IO::Error
        raise WithdrawalAcceptanceUnknown.new(transmission_id, envelope.sender_ship, ex.message)
      end
      unless accepted_response?(response_body)
        raise WithdrawalAcceptanceUnknown.new(
          transmission_id, envelope.sender_ship,
          "repeater returned invalid withdrawal acceptance evidence"
        )
      end
      begin
        outgoing.mark_withdrawal(transmission_id)
      rescue ex : IO::Error | Error
        raise Error.new(
          "repeater accepted withdrawal of #{transmission_id}, but its local marker " +
          "could not be recorded: #{ex.message}"
        )
      end
      record
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

    private def submit_record(record : OutgoingRecord, outgoing : OutgoingStore,
                              initial : Bool,
                              observer : OutgoingObserver?) : Nil
      envelope = record.signed_relay_envelope
      response_body = begin
        remote.post("/v1/transmissions", envelope.to_json)
      rescue ex : Invalid | Unauthorized | NotFound | Conflict | Expired | ProtocolMismatch
        if initial
          begin
            outgoing.discard_initial(record)
          rescue cleanup : IO::Error | Error
            raise Error.new(
              "repeater rejected #{envelope.transmission_id}, but its local outbox evidence " +
              "could not be removed: #{cleanup.message}"
            )
          end
        end
        raise ex
      rescue ex : TransmissionLimited
        raise TransmissionLimited.new(
          ex.retry_after_seconds, envelope.transmission_id, envelope.sender_ship
        )
      rescue ex : Error | IO::Error
        raise AcceptanceUnknown.new(
          envelope.transmission_id, envelope.sender_ship, ex.message
        )
      end
      unless accepted_response?(response_body)
        raise AcceptanceUnknown.new(
          envelope.transmission_id, envelope.sender_ship,
          "repeater returned invalid acceptance evidence"
        )
      end
      begin
        outgoing.settle(envelope.transmission_id)
      rescue ex : IO::Error | Error
        raise Error.new(
          "repeater accepted #{envelope.transmission_id}, but its local outbox evidence " +
          "could not be moved to sent: #{ex.message}"
        )
      end
      observer.try(&.notify(record.signed_transmission))
    end

    private def submit_legacy(envelope : SignedRelayEnvelope, encoded : String,
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
        raise AcceptanceUnknown.new(
          envelope.transmission_id, envelope.sender_ship, ex.message
        )
      end
      unless accepted_response?(response_body)
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

    private def accepted_response?(body : String) : Bool
      RelayAcceptedResponse.from_json(body).accepted?
    rescue JSON::ParseException | JSON::SerializableError
      false
    end

    private def authoring_owner_public_key(radio : ShipRadioIdentity) : String
      if public_key = radio.owner_public_key
        return public_key
      end
      certificate = radio.certificate
      public_key = if certificate.owner_generation == keyring.data.owner_generation
                     keyring.data.owner_public_key
                   else
                     document = inspect_document(keyring.data.ship, all_local_radios: true)
                     owner = document["owner_keys"].as_a.find do |candidate|
                       candidate["generation"].as_i == certificate.owner_generation
                     end || raise(Unauthorized.new("authoring owner key is absent from registry"))
                     owner["public_key"].as_s
                   end
      unless Crypto.verify(
               certificate.unsigned_bytes,
               Crypto.unb64(certificate.owner_signature),
               Crypto.unb64(public_key)
             )
        raise Unauthorized.new("authoring radio certificate is invalid")
      end
      mutate_keyring do
        stored = keyring.data.radio!(radio.generation)
        if existing = stored.owner_public_key
          unless existing == public_key
            raise Unauthorized.new("authoring owner key changed in the local keyring")
          end
        else
          stored.owner_public_key = public_key
        end
      end
      public_key
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
  end
end
