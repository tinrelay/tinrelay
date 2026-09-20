module Tinrelay
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
