require "../spec_helper"

class OwnerRegistryResponseRemote < Tinrelay::Remote
  property document : String

  def initialize(@document)
    super("http://127.0.0.1:8787")
  end

  def post(path : String, body : String) : String
    raise "unexpected registry path" unless path == "/v1/ships/inspect"
    document
  end
end

module TinrelayOwnerRegistryAdoptionSpec
  def self.certificate(generation : Int32, owner_secret : Bytes)
    signing = Tinrelay::Crypto.signing_keypair
    encryption = Tinrelay::Crypto.box_keypair
    certificate = Tinrelay::ShipRadioCertificate.new(
      "beta", generation, Tinrelay::Crypto.b64(signing.public_key),
      Tinrelay::Crypto.b64(encryption.public_key), Time.utc.to_unix, 1
    )
    certificate.owner_signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(certificate.unsigned_bytes, owner_secret)
    )
    certificate
  end

  def self.document(certificate : Tinrelay::ShipRadioCertificate,
                    owner_keys : Array(String)) : String
    links = owner_keys.map do |public_key|
      Tinrelay::OwnerKeyLink.new(1, public_key, "not-a-link")
    end
    document_with_links(certificate, links)
  end

  def self.document_with_links(certificate : Tinrelay::ShipRadioCertificate,
                               links : Array(Tinrelay::OwnerKeyLink)) : String
    {
      ship:       "beta",
      owner_keys: links.map do |link|
        {
          generation:              link.generation,
          public_key:              link.public_key,
          authorization_signature: link.authorization_signature,
        }
      end,
      radio_keys: [{
        generation:            certificate.generation,
        state:                 "active",
        signing_public_key:    certificate.signing_public_key,
        encryption_public_key: certificate.encryption_public_key,
        issued_at:             certificate.issued_at,
        owner_generation:      certificate.owner_generation,
        owner_signature:       certificate.owner_signature,
      }],
    }.to_json
  end
end

describe Tinrelay::Client do
  it "never adopts an unverified duplicate registry owner as the contact pin" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "keyring")
    keyring = Tinrelay::Keyring.create(path, "http://127.0.0.1:8787", "alpha")
    genuine = Tinrelay::Crypto.signing_keypair
    other = Tinrelay::Crypto.signing_keypair
    genuine_public = Tinrelay::Crypto.b64(genuine.public_key)
    other_public = Tinrelay::Crypto.b64(other.public_key)
    first = TinrelayOwnerRegistryAdoptionSpec.certificate(1, genuine.secret_key)
    keyring.mutate do |latest, _owner|
      latest.data.contacts << Tinrelay::ShipContact.new(
        "beta", 1, genuine_public, first, "friend"
      )
    end

    second = TinrelayOwnerRegistryAdoptionSpec.certificate(2, genuine.secret_key)
    remote = OwnerRegistryResponseRemote.new(
      TinrelayOwnerRegistryAdoptionSpec.document(second, [genuine_public, other_public])
    )
    client = Tinrelay::Client.new(keyring, remote)
    client.who("beta")
    adopted = Tinrelay::Keyring.load(path).data.contact!("beta")
    adopted.owner_public_key.should eq(genuine_public)
    adopted.owner_chain.map(&.public_key).should eq([genuine_public])
    adopted.radio_certificate.generation.should eq(2)

    third_other = TinrelayOwnerRegistryAdoptionSpec.certificate(3, other.secret_key)
    remote.document = TinrelayOwnerRegistryAdoptionSpec.document(third_other, [other_public])
    expect_raises(Tinrelay::Unauthorized, "pinned owner key changed") do
      client.who("beta")
    end
    Tinrelay::Keyring.load(path).data.contact!("beta").owner_public_key
      .should eq(genuine_public)

    third_genuine = TinrelayOwnerRegistryAdoptionSpec.certificate(3, genuine.secret_key)
    remote.document = TinrelayOwnerRegistryAdoptionSpec.document(third_genuine, [genuine_public])
    client.who("beta")
    Tinrelay::Keyring.load(path).data.contact!("beta").radio_certificate.generation
      .should eq(3)
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "accepts a signed owner advance while refusing missing and older links" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "keyring")
    keyring = Tinrelay::Keyring.create(path, "http://127.0.0.1:8787", "alpha")
    first_owner = Tinrelay::Crypto.signing_keypair
    next_owner = Tinrelay::Crypto.signing_keypair
    first_public = Tinrelay::Crypto.b64(first_owner.public_key)
    next_public = Tinrelay::Crypto.b64(next_owner.public_key)
    first_certificate = TinrelayOwnerRegistryAdoptionSpec.certificate(1, first_owner.secret_key)
    keyring.mutate do |latest, _owner|
      latest.data.contacts << Tinrelay::ShipContact.new(
        "beta", 1, first_public, first_certificate, "friend"
      )
    end

    next_certificate = TinrelayOwnerRegistryAdoptionSpec.certificate(2, next_owner.secret_key)
    next_certificate.owner_generation = 2
    next_certificate.owner_signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(next_certificate.unsigned_bytes, next_owner.secret_key)
    )
    rotation_signature = Tinrelay::Crypto.b64(Tinrelay::Crypto.sign(
      Tinrelay::OwnerKeyLink.rotation_bytes("beta", 2, next_public), first_owner.secret_key
    ))
    links = [
      Tinrelay::OwnerKeyLink.new(1, first_public),
      Tinrelay::OwnerKeyLink.new(2, next_public, rotation_signature),
    ]
    remote = OwnerRegistryResponseRemote.new(
      TinrelayOwnerRegistryAdoptionSpec.document_with_links(next_certificate, links)
    )
    client = Tinrelay::Client.new(keyring, remote)
    client.who("beta")
    advanced = Tinrelay::Keyring.load(path).data.contact!("beta")
    advanced.owner_generation.should eq(2)
    advanced.owner_public_key.should eq(next_public)
    advanced.owner_chain.map(&.generation).should eq([1, 2])

    missing = TinrelayOwnerRegistryAdoptionSpec.certificate(3, next_owner.secret_key)
    missing.owner_generation = 4
    missing.owner_signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(missing.unsigned_bytes, next_owner.secret_key)
    )
    remote.document = TinrelayOwnerRegistryAdoptionSpec.document_with_links(missing, links)
    expect_raises(Tinrelay::Unauthorized, "owner rotation chain is incomplete") do
      client.who("beta")
    end

    older = TinrelayOwnerRegistryAdoptionSpec.certificate(3, first_owner.secret_key)
    remote.document = TinrelayOwnerRegistryAdoptionSpec.document_with_links(older, links)
    expect_raises(Tinrelay::Unauthorized, "registry returned an older owner generation") do
      client.who("beta")
    end
    Tinrelay::Keyring.load(path).data.contact!("beta").owner_public_key.should eq(next_public)
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
