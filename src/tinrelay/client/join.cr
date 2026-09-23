module Tinrelay
  class Client
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
      rescue ex : Error
        case ex
        when Invalid, NotFound, Conflict, Expired, ProtocolMismatch,
             RegistrationLimited, RegistrationUnavailable
          if candidate = prepared
            candidate.cleanup_token.try do |token|
              candidate.keyring.abandon_join(token)
            end
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
      certificate = RegistryEvidence.radio_certificate(document["ship"].as_s, radio)
      expected = keyring.data.radio!(1).certificate
      unless owner["public_key"].as_s == keyring.data.owner_public_key &&
             certificate.same_certificate?(expected) &&
             certificate.owner_authorized?(Crypto.unb64(keyring.data.owner_public_key))
        raise Unauthorized.new("remote claim does not match the provisional ship identity")
      end
      true
    rescue Unauthorized | NotFound | Unavailable
      false
    end
  end
end
