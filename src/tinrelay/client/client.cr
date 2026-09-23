module Tinrelay
  # Decoding registry evidence does not authenticate its owner or radio key.
  module RegistryEvidence
    def self.radio_certificate(ship : String, radio : JSON::Any) : ShipRadioCertificate
      ShipRadioCertificate.new(
        ship, radio["generation"].as_i.to_i,
        radio["signing_public_key"].as_s, radio["encryption_public_key"].as_s,
        radio["issued_at"].as_i64, radio["owner_generation"].as_i.to_i,
        radio["owner_signature"].as_s
      )
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

    private def refresh_keyring! : Nil
      keyring.refresh
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

    private def unsigned_radio_auth(radio : ShipRadioIdentity? = nil) : RadioAuth
      radio = radio || keyring.data.radio!
      RadioAuth.new(keyring.data.ship, radio.generation, 0_i64)
    end

    private def mutate_keyring(&block : -> T) : T forall T
      mutate_keyring_lifecycle(false) { |_owner| block.call }
    end

    private def mutate_keyring_with_owner(&block : OwnerKeyData -> T) : T forall T
      mutate_keyring_lifecycle(true) { |owner| block.call(owner.not_nil!) }
    end

    private def mutate_keyring_lifecycle(include_owner : Bool,
                                         &block : OwnerKeyData? -> T) : T forall T
      current = keyring
      begin
        current.mutate(include_owner: include_owner) do |latest, owner|
          @keyring = latest
          block.call(owner)
        end
      rescue ex
        current.refresh
        @keyring = current
        raise ex
      end
    end
  end
end
