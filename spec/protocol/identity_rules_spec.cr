require "../spec_helper"

describe Tinrelay::Ids do
  it "keeps protocol source IDs distinct from broader Codex task IDs" do
    source = "12345678-1234-4234-8234-123456789abc"
    task = "019a6d13-2f40-7b21-8c59-5a9d23f11e70"
    rejection = "tr_#{"a" * 32}"

    Tinrelay::Ids.source?("transmission", source).should be_true
    Tinrelay::Ids.source?("hail", source).should be_true
    Tinrelay::Ids.source?("rejected_transmission", rejection).should be_true
    Tinrelay::Ids::TASK_UUID.matches?(task).should be_true
    Tinrelay::Ids.source?("transmission", task).should be_false
    Tinrelay::Ids.source?("unknown", source).should be_false
    Tinrelay::Ids.source?("hail", rejection).should be_false
  end
end

describe Tinrelay::SignedTransmission do
  it "binds only the six routing facts to its relay envelope" do
    transmission = Tinrelay::SignedTransmission.new(
      "12345678-1234-4234-8234-123456789abc", "alpha", 2, "beta", 3,
      1_700_000_000_i64, "receiver", "private words"
    )
    envelope = Tinrelay::SignedRelayEnvelope.new(
      transmission.transmission_id, "alpha", 2, "beta", 3,
      1_700_000_000_i64, 1_700_000_060_i64, "ciphertext", "outer-signature"
    )
    transmission.matches_envelope?(envelope).should be_true

    envelope.expires_at = 1_700_000_001_i64
    envelope.ciphertext = "other ciphertext"
    envelope.signature = "other signature"
    transmission.matches_envelope?(envelope).should be_true

    envelope.transmission_id = Tinrelay::Ids.uuid
    transmission.matches_envelope?(envelope).should be_false
    envelope.transmission_id = transmission.transmission_id
    envelope.sender_ship = "gamma"
    transmission.matches_envelope?(envelope).should be_false
    envelope.sender_ship = "alpha"
    envelope.sender_signing_generation = 4
    transmission.matches_envelope?(envelope).should be_false
    envelope.sender_signing_generation = 2
    envelope.recipient_ship = "gamma"
    transmission.matches_envelope?(envelope).should be_false
    envelope.recipient_ship = "beta"
    envelope.recipient_encryption_generation = 4
    transmission.matches_envelope?(envelope).should be_false
    envelope.recipient_encryption_generation = 3
    envelope.created_at += 1
    transmission.matches_envelope?(envelope).should be_false
  end
end

describe Tinrelay::ShipRadioCertificate do
  it "compares every public certificate fact including the owner signature" do
    original = Tinrelay::ShipRadioCertificate.new(
      "alpha", 2, "signing", "encryption", 1_700_000_000_i64, 3, "owner-signature"
    )
    same = Tinrelay::ShipRadioCertificate.from_json(original.to_json)
    original.same_certificate?(same).should be_true

    changes = [
      Tinrelay::ShipRadioCertificate.new("beta", 2, "signing", "encryption",
        1_700_000_000_i64, 3, "owner-signature"),
      Tinrelay::ShipRadioCertificate.new("alpha", 4, "signing", "encryption",
        1_700_000_000_i64, 3, "owner-signature"),
      Tinrelay::ShipRadioCertificate.new("alpha", 2, "different", "encryption",
        1_700_000_000_i64, 3, "owner-signature"),
      Tinrelay::ShipRadioCertificate.new("alpha", 2, "signing", "different",
        1_700_000_000_i64, 3, "owner-signature"),
      Tinrelay::ShipRadioCertificate.new("alpha", 2, "signing", "encryption",
        1_700_000_001_i64, 3, "owner-signature"),
      Tinrelay::ShipRadioCertificate.new("alpha", 2, "signing", "encryption",
        1_700_000_000_i64, 4, "owner-signature"),
      Tinrelay::ShipRadioCertificate.new("alpha", 2, "signing", "encryption",
        1_700_000_000_i64, 3, "different-signature"),
    ]
    changes.each { |changed| original.same_certificate?(changed).should be_false }
  end
end

describe Tinrelay::OwnerKeyLink do
  it "validates one adjacent owner chain using exact signed rotation bytes" do
    first_key = Tinrelay::Crypto.signing_keypair
    second_key = Tinrelay::Crypto.signing_keypair
    first = Tinrelay::OwnerKeyLink.new(1, Tinrelay::Crypto.b64(first_key.public_key))
    second_public = Tinrelay::Crypto.b64(second_key.public_key)
    bytes = Tinrelay::OwnerKeyLink.rotation_bytes("alpha", 2, second_public)
    signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(bytes, first_key.secret_key)
    )
    second = Tinrelay::OwnerKeyLink.new(2, second_public, signature)

    Tinrelay::OwnerKeyLink.continuity_issue("alpha", first, [second]).should be_nil
    Tinrelay::OwnerKeyLink.continuity_issue("beta", first, [second])
      .should eq("has invalid authorization")
    skipped = Tinrelay::OwnerKeyLink.new(3, second_public, signature)
    Tinrelay::OwnerKeyLink.continuity_issue("alpha", first, [skipped])
      .should eq("is incomplete")
    unsigned = Tinrelay::OwnerKeyLink.new(2, second_public)
    Tinrelay::OwnerKeyLink.continuity_issue("alpha", first, [unsigned])
      .should eq("lacks an authorization")
  end
end
