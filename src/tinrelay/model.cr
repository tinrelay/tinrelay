module Tinrelay
  class ShipRadioCertificate
    include JSON::Serializable

    property ship : String
    property generation : Int32
    property signing_public_key : String
    property encryption_public_key : String
    property issued_at : Int64
    property owner_generation : Int32
    property owner_signature : String

    def initialize(@ship, @generation, @signing_public_key,
                   @encryption_public_key, @issued_at, @owner_generation,
                   @owner_signature = "")
    end

    def unsigned_bytes : Bytes
      Canonical.fields(
        "tinrelay-ship-radio-certificate-v1", ship, generation.to_s,
        signing_public_key, encryption_public_key, issued_at.to_s,
        owner_generation.to_s
      )
    end

    # This is the complete public certificate identity embedded in operations
    # that must bind the owner's authorization, independently of JSON ordering.
    def canonical_bytes : Bytes
      Canonical.fields(
        "tinrelay-ship-radio-certificate-fields-v1", ship,
        generation.to_s, signing_public_key, encryption_public_key,
        issued_at.to_s, owner_generation.to_s, owner_signature
      )
    end

    def identifies_sender?(ship : String, generation : Int32) : Bool
      @ship == ship && @generation == generation
    end

    def owner_authorized?(owner_public_key : Bytes) : Bool
      Crypto.verify(
        unsigned_bytes, Crypto.unb64(owner_signature), owner_public_key
      )
    end

    def same_certificate?(other : ShipRadioCertificate) : Bool
      ship == other.ship && generation == other.generation &&
        signing_public_key == other.signing_public_key &&
        encryption_public_key == other.encryption_public_key &&
        issued_at == other.issued_at && owner_generation == other.owner_generation &&
        owner_signature == other.owner_signature
    end
  end

  class OwnerKeyLink
    include JSON::Serializable

    property generation : Int32
    property public_key : String
    property authorization_signature : String?

    def initialize(@generation, @public_key, @authorization_signature = nil)
    end

    def self.rotation_bytes(ship : String, generation : Int32,
                            public_key : String) : Bytes
      Canonical.fields(
        "tinrelay-owner-rotation-v1", ship, generation.to_s, public_key
      )
    end

    def self.continuity_issue(ship : String, anchor : OwnerKeyLink,
                              links : Array(OwnerKeyLink)) : String?
      previous = anchor
      links.each do |link|
        return "is incomplete" unless link.generation == previous.generation + 1
        signature = link.authorization_signature ||
                    return "lacks an authorization"
        unless Crypto.verify(
                 rotation_bytes(ship, link.generation, link.public_key),
                 Crypto.unb64(signature), Crypto.unb64(previous.public_key)
               )
          return "has invalid authorization"
        end
        previous = link
      end
      nil
    end
  end

  # SignedRelayEnvelope authenticates the sealed radio emission. The repeater and
  # recipient can reject changed visible routing facts or ciphertext without opening it.
  class SignedRelayEnvelope
    include JSON::Serializable

    property object_version : Int32
    property protocol : Int32
    property transmission_id : String
    property sender_ship : String
    property sender_signing_generation : Int32
    property recipient_ship : String
    property recipient_encryption_generation : Int32
    property created_at : Int64
    property expires_at : Int64
    property ciphertext : String
    property signature : String

    def initialize(@transmission_id, @sender_ship,
                   @sender_signing_generation, @recipient_ship,
                   @recipient_encryption_generation, @created_at, @expires_at,
                   @ciphertext, @signature = "",
                   @protocol = PROTOCOL, @object_version = 1)
    end

    def signing_bytes : Bytes
      Canonical.fields(
        "tinrelay-signed-relay-envelope-v1", object_version.to_s,
        protocol.to_s, transmission_id, sender_ship,
        sender_signing_generation.to_s, recipient_ship,
        recipient_encryption_generation.to_s, created_at.to_s,
        expires_at.to_s, ciphertext
      )
    end

    def submission_evidence
      {
        state:           "accepted",
        sender_ship:     sender_ship,
        recipient_ship:  recipient_ship,
        transmission_id: transmission_id,
      }
    end
  end

  # SignedTransmission preserves ship-level provenance of the exact words and
  # private context independently of relay retention and private receive-key lifetime.
  class SignedTransmission
    include JSON::Serializable

    property object_version : Int32
    property protocol : Int32
    property transmission_id : String
    property sender_ship : String
    property sender_signing_generation : Int32
    property recipient_ship : String
    property recipient_encryption_generation : Int32
    property created_at : Int64
    property to_label : String
    property from_label : String?
    property body : String
    property signature : String

    def initialize(@transmission_id, @sender_ship,
                   @sender_signing_generation, @recipient_ship,
                   @recipient_encryption_generation, @created_at, @to_label,
                   @body, @from_label = nil,
                   @signature = "", @protocol = PROTOCOL,
                   @object_version = 1)
    end

    def matches_envelope?(envelope : SignedRelayEnvelope) : Bool
      transmission_id == envelope.transmission_id &&
        sender_ship == envelope.sender_ship &&
        sender_signing_generation == envelope.sender_signing_generation &&
        recipient_ship == envelope.recipient_ship &&
        recipient_encryption_generation == envelope.recipient_encryption_generation &&
        created_at == envelope.created_at
    end

    def signing_bytes : Bytes
      Canonical.fields(
        "tinrelay-signed-transmission-v1", object_version.to_s,
        protocol.to_s, transmission_id, sender_ship,
        sender_signing_generation.to_s, recipient_ship,
        recipient_encryption_generation.to_s, created_at.to_s, to_label,
        from_label || "", body
      )
    end
  end

  class RadioAuth
    include JSON::Serializable

    property ship : String
    property radio_generation : Int32
    property timestamp : Int64
    property signature : String

    def initialize(@ship, @radio_generation, @timestamp, @signature = "")
    end

    def signing_bytes(action : String, payload : Bytes) : Bytes
      Canonical.fields(
        "tinrelay-radio-action-v1", action, ship,
        radio_generation.to_s, timestamp.to_s,
        Digest::SHA256.hexdigest(payload)
      )
    end
  end

  class OwnerAuth
    include JSON::Serializable

    property ship : String
    property owner_generation : Int32
    property admin_generation : Int64
    property timestamp : Int64
    property signature : String

    def initialize(@ship, @owner_generation, @admin_generation,
                   @timestamp, @signature = "")
    end

    def signing_bytes(action : String, payload : Bytes) : Bytes
      Canonical.fields(
        "tinrelay-owner-action-v1", action, ship,
        owner_generation.to_s, admin_generation.to_s, timestamp.to_s,
        Digest::SHA256.hexdigest(payload)
      )
    end
  end

  class ShipClaim
    include JSON::Serializable

    property ship : String
    property owner_public_key : String
    property radio_certificate : ShipRadioCertificate

    def initialize(@ship, @owner_public_key, @radio_certificate)
    end
  end

  class Hail
    include JSON::Serializable

    property protocol : Int32
    property hail_id : String
    property sender_ship : String
    property sender_signing_generation : Int32
    property recipient_ship : String
    property created_at : Int64
    property expires_at : Int64
    property signature : String

    def initialize(@hail_id, @sender_ship, @sender_signing_generation,
                   @recipient_ship, @created_at, @expires_at,
                   @signature = "", @protocol = PROTOCOL)
    end

    def signing_bytes : Bytes
      Canonical.fields(
        "tinrelay-hail-v1", protocol.to_s, hail_id, sender_ship,
        sender_signing_generation.to_s, recipient_ship, created_at.to_s,
        expires_at.to_s
      )
    end

    def signed_by?(radio_public_key : Bytes) : Bool
      Crypto.verify(signing_bytes, Crypto.unb64(signature), radio_public_key)
    end

    def submission_evidence
      {
        state:          "accepted",
        sender_ship:    sender_ship,
        recipient_ship: recipient_ship,
        hail_id:        hail_id,
      }
    end
  end

  class HailDelivery
    include JSON::Serializable

    property hail : Hail
    property sender_owner_public_key : String
    property sender_radio_certificate : ShipRadioCertificate
    property owner_chain : Array(OwnerKeyLink)
    property radio_chain : Array(RadioCertificateLink)

    def initialize(@hail, @sender_owner_public_key,
                   @sender_radio_certificate,
                   @owner_chain = [] of OwnerKeyLink,
                   @radio_chain = [] of RadioCertificateLink)
    end
  end

  class RadioCertificateLink
    include JSON::Serializable

    property certificate : ShipRadioCertificate
    property prior_radio_signature : String?

    def initialize(@certificate, @prior_radio_signature = nil)
    end
  end

  class ContactUpdate
    include JSON::Serializable

    property ship : String
    property to_generation : Int32
    property owner_chain : Array(OwnerKeyLink)
    property chain : Array(RadioCertificateLink)

    def initialize(@ship, @to_generation, @owner_chain, @chain)
    end
  end

  class HailAck
    include JSON::Serializable

    property hail_id : String
    property auth : RadioAuth

    def initialize(@hail_id, @auth)
    end

    def payload : Bytes
      Canonical.fields(hail_id)
    end
  end

  class ShipInspection
    include JSON::Serializable

    property target_ship : String
    property auth : RadioAuth

    def initialize(@target_ship, @auth)
    end

    def payload : Bytes
      Canonical.fields(target_ship)
    end
  end

  class RadioWaitRequest
    include JSON::Serializable

    property hold_seconds : Int32
    property known_contact_generations : Hash(String, Int32)
    property auth : RadioAuth

    def initialize(@hold_seconds, @auth,
                   @known_contact_generations = {} of String => Int32)
    end

    def payload : Bytes
      Canonical.fields(
        hold_seconds.to_s,
        known_contact_generations.keys.sort.map do |ship|
          "#{ship}:#{known_contact_generations[ship]}"
        end.join(",")
      )
    end
  end

  class TransmissionAck
    include JSON::Serializable

    property transmission_id : String
    property auth : RadioAuth

    def initialize(@transmission_id, @auth)
    end

    def payload : Bytes
      Canonical.fields(transmission_id)
    end
  end

  class TransmissionWithdrawal
    include JSON::Serializable
    include JSON::Serializable::Strict

    property transmission_id : String
    property auth : RadioAuth

    def initialize(@transmission_id, @auth)
    end

    def payload : Bytes
      Canonical.fields(transmission_id)
    end
  end

  class RelationshipClose
    include JSON::Serializable

    property peer_ship : String
    property retained_ships : Array(String)
    property certificate : ShipRadioCertificate
    property prior_radio_signature : String
    property auth : OwnerAuth

    def initialize(@peer_ship, @retained_ships, @certificate,
                   @prior_radio_signature, @auth)
    end

    def payload : Bytes
      Canonical.fields(
        peer_ship, retained_ships.sort.join(","),
        String.new(certificate.canonical_bytes),
        prior_radio_signature
      )
    end
  end

  class RetuneAck
    include JSON::Serializable

    property owner_ship : String
    property to_generation : Int32
    property auth : RadioAuth

    def initialize(@owner_ship, @to_generation, @auth)
    end

    def payload : Bytes
      Canonical.fields(owner_ship, to_generation.to_s)
    end
  end

  class RelationshipAllow
    include JSON::Serializable

    property peer_ship : String
    property hail_id : String
    property auth : RadioAuth

    def initialize(@peer_ship, @hail_id, @auth)
    end

    def payload : Bytes
      Canonical.fields(peer_ship, hail_id)
    end
  end

  class OwnerRotation
    include JSON::Serializable

    property new_generation : Int32
    property new_public_key : String
    property prior_signature : String
    property auth : OwnerAuth

    def initialize(@new_generation, @new_public_key, @prior_signature,
                   @auth)
    end

    def payload : Bytes
      Canonical.fields(new_generation.to_s, new_public_key, prior_signature)
    end
  end

  class ShipChange
    include JSON::Serializable

    property operation : String
    property auth : OwnerAuth

    def initialize(@operation, @auth)
    end

    def payload : Bytes
      Canonical.fields(operation)
    end
  end

  class RadioWaitResponse
    include JSON::Serializable

    property envelope : SignedRelayEnvelope?
    property hail : HailDelivery?
    property contact_updates : Array(ContactUpdate)

    def initialize(@envelope = nil, @hail = nil,
                   @contact_updates = [] of ContactUpdate)
    end

    def empty? : Bool
      !envelope && !hail && contact_updates.empty?
    end
  end

  class RelayAcceptedResponse
    include JSON::Serializable
    include JSON::Serializable::Strict

    getter state : String

    def initialize(@state = "accepted")
    end

    def accepted? : Bool
      state == "accepted"
    end
  end

  class OutgoingOwnerEvidence
    include JSON::Serializable
    include JSON::Serializable::Strict

    getter generation : Int32
    getter public_key : String

    def initialize(@generation, @public_key)
    end
  end

  class OutgoingRecord
    include JSON::Serializable
    include JSON::Serializable::Strict

    getter format : Int32
    getter signed_transmission : SignedTransmission
    getter signed_relay_envelope : SignedRelayEnvelope
    getter authoring_radio_certificate : ShipRadioCertificate
    getter authoring_owner : OutgoingOwnerEvidence

    def initialize(@signed_transmission, @signed_relay_envelope,
                   @authoring_radio_certificate, @authoring_owner,
                   @format = 1)
    end

    def transmission_id : String
      signed_transmission.transmission_id
    end
  end

  class OutgoingWithdrawalMarker
    include JSON::Serializable
    include JSON::Serializable::Strict

    getter format : Int32
    getter transmission_id : String

    def initialize(@transmission_id, @format = 1)
    end
  end

  abstract class SpoolRecord
    include JSON::Serializable
    include JSON::Serializable::Strict

    use_json_discriminator "kind", {
      transmission:          TransmissionSpoolRecord,
      rejected_transmission: RejectedTransmissionSpoolRecord,
      hail:                  HailSpoolRecord,
    }

    getter format : Int32
    getter kind : String
    getter source_id : String
    getter received_at : Int64

    @[JSON::Field(ignore: true)]
    property routed : Bool = false

    protected def initialize(@kind, @source_id, @received_at, @format = 2)
    end
  end

  class TransmissionSpoolRecord < SpoolRecord
    getter sender_ship : String
    getter recipient_ship : String
    getter to_label : String
    getter from_label : String?
    getter signed_transmission : SignedTransmission
    getter sender_radio_certificate : ShipRadioCertificate
    getter sender_owner_chain : Array(OwnerKeyLink)

    def initialize(received_at : Int64, @sender_ship : String,
                   @recipient_ship : String, @to_label : String,
                   @from_label : String?,
                   @signed_transmission : SignedTransmission,
                   @sender_radio_certificate : ShipRadioCertificate,
                   @sender_owner_chain : Array(OwnerKeyLink),
                   format : Int32 = 2)
      super("transmission", signed_transmission.transmission_id, received_at, format)
    end

    def transmission_id : String
      signed_transmission.transmission_id
    end
  end

  class RejectedTransmissionSpoolRecord < SpoolRecord
    getter transmission_id : String
    getter rejection_reason : String

    def initialize(evidence_id : String, received_at : Int64,
                   @transmission_id : String, @rejection_reason : String,
                   format : Int32 = 2)
      super("rejected_transmission", evidence_id, received_at, format)
    end
  end

  class HailSpoolRecord < SpoolRecord
    getter hail : Hail
    getter sender_owner_chain : Array(OwnerKeyLink)
    getter sender_radio_certificate : ShipRadioCertificate
    getter hail_contact_state : String

    def initialize(received_at : Int64,
                   @hail : Hail,
                   @sender_owner_chain : Array(OwnerKeyLink),
                   @sender_radio_certificate : ShipRadioCertificate,
                   @hail_contact_state : String,
                   format : Int32 = 2)
      super("hail", hail.hail_id, received_at, format)
    end

    def hail_id : String
      hail.hail_id
    end

    def sender_ship : String
      hail.sender_ship
    end

    def recipient_ship : String
      hail.recipient_ship
    end
  end

  class RadioEvent
    include JSON::Serializable

    property contract : String
    property kind : String
    property source_id : String
    property wrapper : String
    property name : String?

    def initialize(@kind, @source_id, @wrapper, @name = nil,
                   @contract = "tinrelay-radio-wait-v2")
    end
  end

  class ProtocolMismatchEvidence
    include JSON::Serializable
    include JSON::Serializable::Strict

    getter error : String
    getter client_protocol : Int32
    getter supported_min : Int32
    getter supported_max : Int32
    getter relation : String

    def initialize(@error, @client_protocol, @supported_min,
                   @supported_max, @relation)
    end
  end

  class RotationLimitEvidence
    include JSON::Serializable
    include JSON::Serializable::Strict

    getter error : String
    getter retry_after_seconds : Int64

    def initialize(@error, @retry_after_seconds)
    end
  end

  class MaintenanceEvidence
    include JSON::Serializable
    include JSON::Serializable::Strict

    @[JSON::Field(ignore: true)]
    @back_at_present : Bool = false

    getter error : String
    @[JSON::Field(presence: true)]
    getter back_at : String?

    def initialize(@error, @back_at = nil)
      @back_at_present = true
    end

    def back_at_present? : Bool
      @back_at_present
    end
  end

  module Canonical
    def self.fields(*values : String) : Bytes
      io = IO::Memory.new
      values.each do |value|
        bytes = value.to_slice
        io.write_bytes(bytes.size.to_u32, IO::ByteFormat::BigEndian)
        io.write(bytes)
      end
      io.to_slice
    end
  end
end
