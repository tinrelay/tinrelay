require "../spec_helper"

module TinrelaySpoolRecordSpec
  LOCAL_ID = "tr_0123456789abcdef0123456789abcdef"

  def self.certificate : Tinrelay::ShipRadioCertificate
    Tinrelay::ShipRadioCertificate.new(
      "alpha", 2, "signing-public", "encryption-public", 10_i64, 1,
      "owner-signature"
    )
  end

  def self.transmission : Tinrelay::SignedTransmission
    Tinrelay::SignedTransmission.new(
      "11111111-1111-4111-8111-111111111111",
      "alpha", 2, "beta", 3, 20_i64, "steward", "exact words",
      from_label: "caller", signature: "transmission-signature"
    )
  end

  def self.records : Array(Tinrelay::SpoolRecord)
    [
      Tinrelay::TransmissionSpoolRecord.new(
        local_id: LOCAL_ID, received_at: 30_i64,
        relay_transmission_id: transmission.transmission_id,
        sender_ship: "alpha", recipient_ship: "beta",
        to_label: "steward", from_label: "caller",
        signed_transmission: transmission,
        sender_radio_certificate: certificate,
        sender_owner_chain: [Tinrelay::OwnerKeyLink.new(1, "owner-public")]
      ),
      Tinrelay::RejectedTransmissionSpoolRecord.new(
        local_id: LOCAL_ID, received_at: 30_i64,
        relay_transmission_id: transmission.transmission_id,
        rejection_reason: "unusable_envelope"
      ),
      Tinrelay::HailSpoolRecord.new(
        local_id: LOCAL_ID, received_at: 30_i64,
        hail: Tinrelay::Hail.new(
          "33333333-3333-4333-8333-333333333333",
          "alpha", 2, "beta", 20_i64, 40_i64, "hail-signature"
        ),
        sender_owner_chain: [Tinrelay::OwnerKeyLink.new(1, "owner-public")],
        sender_radio_certificate: certificate,
        hail_contact_state: "known_prior_contact"
      ),
    ] of Tinrelay::SpoolRecord
  end
end

describe "discriminated local spool evidence" do
  it "round trips each explicit evidence shape through the common parser" do
    expected_types = [
      Tinrelay::TransmissionSpoolRecord,
      Tinrelay::RejectedTransmissionSpoolRecord,
      Tinrelay::HailSpoolRecord,
    ]

    TinrelaySpoolRecordSpec.records.zip(expected_types).each do |record, expected_type|
      parsed = Tinrelay::SpoolRecord.from_json(record.to_json)
      parsed.class.should eq(expected_type)
      parsed.to_json.should eq(record.to_json)
    end
  end

  it "rejects fields belonging to another evidence kind" do
    TinrelaySpoolRecordSpec.records.each do |record|
      document = JSON.parse(record.to_json).as_h
      foreign_field = case record
                      when Tinrelay::TransmissionSpoolRecord
                        "hail_id"
                      when Tinrelay::RejectedTransmissionSpoolRecord
                        "sender_ship"
                      when Tinrelay::HailSpoolRecord
                        "signed_transmission"
                      else
                        raise "unexpected spool record type"
                      end
      document[foreign_field] = JSON::Any.new("cross-kind data")

      expect_raises(JSON::SerializableError) do
        Tinrelay::SpoolRecord.from_json(document.to_json)
      end
    end
  end

  it "rejects an unknown kind and a missing required kind-specific field" do
    unknown = JSON.parse(TinrelaySpoolRecordSpec.records.first.to_json).as_h
    unknown["kind"] = JSON::Any.new("unknown")
    expect_raises(JSON::SerializableError) do
      Tinrelay::SpoolRecord.from_json(unknown.to_json)
    end

    incomplete = JSON.parse(TinrelaySpoolRecordSpec.records.first.to_json).as_h
    incomplete.delete("signed_transmission")
    expect_raises(JSON::SerializableError) do
      Tinrelay::SpoolRecord.from_json(incomplete.to_json)
    end
  end
end
