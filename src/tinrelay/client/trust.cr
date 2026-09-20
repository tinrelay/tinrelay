module Tinrelay
  class Client
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
  end
end
