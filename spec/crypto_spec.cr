require "./spec_helper"

describe Tinrelay::Crypto do
  it "namespaces the ship radio certificate signature" do
    fixture = JSON.parse(File.read(
      File.expand_path("fixtures/certificate_canonical_vector.json", __DIR__)
    ))
    fields = fixture["certificate"]
    certificate = Tinrelay::ShipRadioCertificate.new(
      ship: fields["ship"].as_s,
      generation: fields["generation"].as_i.to_i,
      signing_public_key: fields["signing_public_key"].as_s,
      encryption_public_key: fields["encryption_public_key"].as_s,
      issued_at: fields["issued_at"].as_i64,
      owner_generation: fields["owner_generation"].as_i.to_i,
      owner_signature: fields["owner_signature"].as_s
    )

    certificate.unsigned_bytes.should eq(Tinrelay::Canonical.fields(
      "tinrelay-ship-radio-certificate-v1",
      "alpha",
      "2",
      "signing-key",
      "encryption-key",
      "1750000000",
      "3"
    ))
    certificate.canonical_bytes.hexstring.should eq(fixture["certificate_hex"].as_s)
    auth = Tinrelay::OwnerAuth.new("alpha", 3, 7_i64, 1_750_000_001_i64)
    close = Tinrelay::RelationshipClose.new(
      fixture["peer_ship"].as_s,
      fixture["retained_ships"].as_a.map(&.as_s), certificate,
      fixture["prior_radio_signature"].as_s, auth
    )
    close.payload.hexstring.should eq(
      fixture["relationship_close_payload_hex"].as_s
    )
  end

  it "matches the checked-in Ed25519 fixture and detects tampering" do
    fixture = JSON.parse(File.read(File.expand_path("fixtures/signing_vector.json", __DIR__)))
    seed = Tinrelay::Crypto.unb64(fixture["seed"].as_s)
    keys = Tinrelay::Crypto.signing_keypair(seed)
    message = fixture["message"].as_s.to_slice
    Tinrelay::Crypto.b64(keys.public_key).should eq(fixture["public_key"].as_s)
    signature = Tinrelay::Crypto.sign(message, keys.secret_key)
    Tinrelay::Crypto.b64(signature).should eq(fixture["signature"].as_s)
    Tinrelay::Crypto.verify(message, signature, keys.public_key).should be_true
    Tinrelay::Crypto.verify("changed".to_slice, signature, keys.public_key).should be_false
  end

  it "authenticates sealed-box ciphertext" do
    recipient = Tinrelay::Crypto.box_keypair
    ciphertext = Tinrelay::Crypto.seal("private transmission".to_slice, recipient.public_key)
    plaintext = Tinrelay::Crypto.open(
      ciphertext,
      recipient.public_key,
      recipient.secret_key
    )
    String.new(plaintext).should eq("private transmission")
    ciphertext[0] ^= 1
    expect_raises(Tinrelay::Unauthorized) do
      Tinrelay::Crypto.open(ciphertext, recipient.public_key, recipient.secret_key)
    end
  end

  it "zeroes a transient secret buffer through libsodium" do
    secret = Bytes[1_u8, 2_u8, 3_u8, 4_u8]

    Tinrelay::Crypto.memzero(secret)

    secret.should eq(Bytes.new(4))
  end
end
