require "../spec_helper"

module TinrelayShipClaimSpec
  HEADERS = HTTP::Headers{
    "Content-Type"        => "application/json",
    "X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s,
  }

  def self.claim(ship : String, owner, signing, encryption,
                 now : Int64 = Time.utc.to_unix) : Tinrelay::ShipClaim
    certificate = Tinrelay::ShipRadioCertificate.new(
      ship, 1, Tinrelay::Crypto.b64(signing.public_key),
      Tinrelay::Crypto.b64(encryption.public_key), now, 1
    )
    certificate.owner_signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(certificate.unsigned_bytes, owner.secret_key)
    )
    Tinrelay::ShipClaim.new(
      ship, Tinrelay::Crypto.b64(owner.public_key), certificate
    )
  end

  def self.submit(origin : String, claim : Tinrelay::ShipClaim) : HTTP::Client::Response
    HTTP::Client.post("#{origin}/v1/join", HEADERS, claim.to_json)
  end
end

describe "open ship claims" do
  it "claims an available chosen name without creating a contact" do
    TinrelaySpec.with_server do |root, origin, api|
      ship = Tinrelay::Client.join(
        File.join(root, "first.keyring"), origin, "first-ship")

      ship.keyring.data.contacts.should be_empty
      api.database.db.query_one(
        "SELECT name FROM ships WHERE name = ?", "first-ship", as: String
      ).should eq("first-ship")
      api.database.db.scalar("SELECT COUNT(*) FROM relationships").should eq(0)
    end
  end

  it "allows exactly one racing claimant and removes the loser's provisional keys" do
    TinrelaySpec.with_server do |root, origin, api|
      results = Channel(Tuple(Int32, Exception?)).new
      2.times do |index|
        spawn do
          begin
            Tinrelay::Client.join(
              File.join(root, "racer-#{index}.keyring"), origin, "one-name")
            results.send({index, nil})
          rescue ex
            results.send({index, ex})
          end
        end
      end

      outcomes = 2.times.map { TinrelaySpec.receive(results) }.to_a
      outcomes.count { |_, error| error.nil? }.should eq(1)
      loser, error = outcomes.find { |outcome| !outcome[1].nil? }.not_nil!
      error.should be_a(Tinrelay::Conflict)
      File.exists?(File.join(root, "racer-#{loser}.keyring")).should be_false
      File.exists?(File.join(root, "racer-#{loser}.keyring.owner")).should be_false
      api.database.db.scalar(
        "SELECT COUNT(*) FROM ships WHERE name = 'one-name'"
      ).should eq(1)
      api.database.db.scalar("SELECT COUNT(*) FROM registration_events").should eq(1_i64)
    end
  end

  it "rejects claims whose ship identity and owner authorization disagree" do
    TinrelaySpec.with_server do |root, origin, api|
      keyring = Tinrelay::Keyring.create(
        File.join(root, "candidate.keyring"), origin, "candidate")
      certificate = keyring.data.radio!.certificate

      wrong_ship = Tinrelay::ShipClaim.new(
        "substitute", keyring.data.owner_public_key, certificate
      )
      headers = HTTP::Headers{
        "Content-Type"        => "application/json",
        "X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s,
      }
      HTTP::Client.post(
        "#{origin}/v1/join", headers, wrong_ship.to_json
      ).status_code.should eq(400)

      changed_certificate = Tinrelay::ShipRadioCertificate.from_json(certificate.to_json)
      changed_certificate.owner_signature = Tinrelay::Crypto.b64(Tinrelay::Crypto.random(64))
      invalid_signature = Tinrelay::ShipClaim.new(
        "candidate", keyring.data.owner_public_key, changed_certificate
      )
      HTTP::Client.post(
        "#{origin}/v1/join", headers, invalid_signature.to_json
      ).status_code.should eq(401)
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(0)
    end
  end

  it "rejects an owner-authorized claim with a wrong-sized radio encryption key" do
    TinrelaySpec.with_server do |root, origin, api|
      keyring = Tinrelay::Keyring.create(
        File.join(root, "oversized.keyring"), origin, "oversized")
      certificate = keyring.data.radio!.certificate
      certificate.encryption_public_key = Tinrelay::Crypto.b64(Bytes.new(40_000, 1_u8))
      owner = keyring.owner
      certificate.owner_signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.sign(
          certificate.unsigned_bytes,
          Tinrelay::Crypto.unb64(owner.key.secret_key)
        )
      )
      claim = Tinrelay::ShipClaim.new(
        keyring.data.ship, keyring.data.owner_public_key, certificate
      )
      headers = HTTP::Headers{
        "Content-Type"        => "application/json",
        "X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s,
      }

      response = HTTP::Client.post("#{origin}/v1/join", headers, claim.to_json)

      response.status_code.should eq(400)
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(0)
      api.database.db.scalar("SELECT COUNT(*) FROM ship_radio_keys").should eq(0)
    end
  end

  it "rejects a wrong-sized owner key before storing permanent identity" do
    TinrelaySpec.with_server do |root, origin, api|
      keyring = Tinrelay::Keyring.create(
        File.join(root, "oversized-owner.keyring"), origin, "oversized-owner")
      claim = Tinrelay::ShipClaim.new(
        keyring.data.ship,
        Tinrelay::Crypto.b64(Bytes.new(Tinrelay::Crypto::SIGN_PUBLIC_BYTES + 1)),
        keyring.data.radio!.certificate
      )

      response = HTTP::Client.post(
        "#{origin}/v1/join", TinrelayShipClaimSpec::HEADERS, claim.to_json
      )

      response.status_code.should eq(400)
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(0)
      api.database.db.scalar("SELECT COUNT(*) FROM ship_owner_keys").should eq(0)
    end
  end

  it "charges only valid claims to the registration windows" do
    TinrelaySpec.with_server do |_root, origin, api|
      owner = Tinrelay::Crypto.signing_keypair
      signing = Tinrelay::Crypto.signing_keypair
      encryption = Tinrelay::Crypto.box_keypair

      malformed_name = TinrelayShipClaimSpec.claim(
        "Invalid!", owner, signing, encryption
      )
      TinrelayShipClaimSpec.submit(origin, malformed_name).status_code.should eq(400)

      malformed_key = TinrelayShipClaimSpec.claim(
        "malformed-key", owner, signing, encryption
      )
      malformed_key.owner_public_key = Tinrelay::Crypto.b64(
        Bytes.new(Tinrelay::Crypto::SIGN_PUBLIC_BYTES - 1)
      )
      TinrelayShipClaimSpec.submit(origin, malformed_key).status_code.should eq(400)

      invalid = TinrelayShipClaimSpec.claim(
        "invalid", owner, signing, encryption
      )
      invalid.radio_certificate.owner_signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.random(Tinrelay::Crypto::SIGNATURE_BYTES)
      )
      TinrelayShipClaimSpec.submit(origin, invalid).status_code.should eq(401)

      allowance = Tinrelay::RegistrationAllowances::DEFAULT_PER_SOURCE_DAY
      allowance.times do |index|
        claim = TinrelayShipClaimSpec.claim(
          "ship-#{index}", owner, signing, encryption
        )
        TinrelayShipClaimSpec.submit(origin, claim).status_code.should eq(201)
      end

      limited = TinrelayShipClaimSpec.submit(
        origin,
        TinrelayShipClaimSpec.claim("one-too-many", owner, signing, encryption)
      )
      limited.status_code.should eq(429)
      limited.headers["Retry-After"].to_i.should be > 0
      api.database.db.scalar("SELECT COUNT(*) FROM ships").as(Int64)
        .should eq(allowance)
      api.database.db.scalar("SELECT COUNT(*) FROM registration_events").as(Int64)
        .should eq(allowance)
    end
  end
end
