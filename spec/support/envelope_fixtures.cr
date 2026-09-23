module TinrelaySpec
  class CaptureRemote < Tinrelay::Remote
    getter captured = [] of Tinrelay::SignedRelayEnvelope

    def post(path : String, body : String) : String
      if path == "/v1/transmissions"
        captured << Tinrelay::SignedRelayEnvelope.from_json(body)
        %({"state":"accepted"})
      else
        super
      end
    end
  end

  def self.reseal(envelope : Tinrelay::SignedRelayEnvelope,
                  transmission : Tinrelay::SignedTransmission,
                  sender : Tinrelay::Client, recipient : Tinrelay::Client,
                  resign_inner : Bool) : Tinrelay::SignedRelayEnvelope
    sender_radio = sender.keyring.data.radio!(envelope.sender_signing_generation)
    if resign_inner
      transmission.signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.sign(
          transmission.signing_bytes,
          Tinrelay::Crypto.unb64(sender_radio.signing.secret_key)
        )
      )
    end
    recipient_radio = recipient.keyring.data.radio!(envelope.recipient_encryption_generation)
    changed = Tinrelay::SignedRelayEnvelope.from_json(envelope.to_json)
    changed.ciphertext = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.seal(
        transmission.to_json.to_slice,
        Tinrelay::Crypto.unb64(recipient_radio.encryption.public_key)
      )
    )
    changed.signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        changed.signing_bytes,
        Tinrelay::Crypto.unb64(sender_radio.signing.secret_key)
      )
    )
    changed
  end
end
