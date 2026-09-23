module TinrelaySpec
  def self.valid_claim(ship : String, issued_at : Int64 = Time.utc.to_unix) : Tinrelay::ShipClaim
    owner = Tinrelay::Crypto.signing_keypair
    signing = Tinrelay::Crypto.signing_keypair
    encryption = Tinrelay::Crypto.box_keypair
    certificate = Tinrelay::ShipRadioCertificate.new(
      ship, 1, Tinrelay::Crypto.b64(signing.public_key),
      Tinrelay::Crypto.b64(encryption.public_key), issued_at, 1
    )
    certificate.owner_signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(certificate.unsigned_bytes, owner.secret_key)
    )
    Tinrelay::ShipClaim.new(ship, Tinrelay::Crypto.b64(owner.public_key), certificate)
  end

  def self.relationship_close(client : Tinrelay::Client, peer : String,
                              radio_generation : Int32, owner_generation : Int32,
                              admin_generation : Int64, now : Int64) : Tinrelay::RelationshipClose
    prior = client.keyring.data.radio!
    owner = client.keyring.owner.key
    signing = Tinrelay::Crypto.signing_keypair
    encryption = Tinrelay::Crypto.box_keypair
    certificate = Tinrelay::ShipRadioCertificate.new(
      client.keyring.data.ship, radio_generation + 1,
      Tinrelay::Crypto.b64(signing.public_key),
      Tinrelay::Crypto.b64(encryption.public_key), now, owner_generation
    )
    certificate.owner_signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        certificate.unsigned_bytes, Tinrelay::Crypto.unb64(owner.secret_key)
      )
    )
    prior_signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        certificate.unsigned_bytes, Tinrelay::Crypto.unb64(prior.signing.secret_key)
      )
    )
    auth = Tinrelay::OwnerAuth.new(
      client.keyring.data.ship, owner_generation, admin_generation, now
    )
    closure = Tinrelay::RelationshipClose.new(
      peer, [] of String, certificate, prior_signature, auth
    )
    auth.signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        auth.signing_bytes("relationship.close", closure.payload),
        Tinrelay::Crypto.unb64(owner.secret_key)
      )
    )
    closure
  end

  def self.seed_radio_history(api : Tinrelay::API, client : Tinrelay::Client,
                              owner_generation : Int32, revoked_at : Array(Int64?),
                              issued_at : Int64) : Int32
    return 1 if revoked_at.empty?
    ship = client.keyring.data.ship
    radio = client.keyring.data.radio!
    owner = client.keyring.owner.key
    api.database.db.transaction do |transaction|
      connection = transaction.connection
      connection.exec(
        "UPDATE ship_radio_keys SET state = 'rotated', revoked_at = ? " +
        "WHERE ship = ? AND generation = 1",
        revoked_at.first, ship
      )
      revoked_at.each_with_index do |timestamp, index|
        generation = index + 1
        next if generation == 1
        connection.exec(
          "INSERT INTO ship_radio_keys(" +
          "ship, generation, signing_public_key, encryption_public_key, " +
          "state, issued_at, owner_generation, owner_signature, revoked_at" +
          ") VALUES (?, ?, ?, ?, 'rotated', 0, ?, ?, ?)",
          ship, generation, Tinrelay::Crypto.signing_keypair.public_key,
          Tinrelay::Crypto.box_keypair.public_key, owner_generation,
          Bytes.new(Tinrelay::Crypto::SIGNATURE_BYTES), timestamp
        )
      end
      active_generation = revoked_at.size + 1
      certificate = Tinrelay::ShipRadioCertificate.new(
        ship, active_generation, radio.signing.public_key,
        radio.encryption.public_key, issued_at, owner_generation
      )
      certificate.owner_signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.sign(
          certificate.unsigned_bytes, Tinrelay::Crypto.unb64(owner.secret_key)
        )
      )
      connection.exec(
        "INSERT INTO ship_radio_keys(" +
        "ship, generation, signing_public_key, encryption_public_key, " +
        "state, issued_at, owner_generation, owner_signature" +
        ") VALUES (?, ?, ?, ?, 'active', ?, ?, ?)",
        ship, active_generation,
        Tinrelay::Crypto.unb64(radio.signing.public_key),
        Tinrelay::Crypto.unb64(radio.encryption.public_key), issued_at,
        owner_generation, Tinrelay::Crypto.unb64(certificate.owner_signature)
      )
      active_generation
    end.not_nil!.to_i
  end
end
