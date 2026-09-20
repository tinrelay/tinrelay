module Tinrelay
  class Client
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
  end
end
