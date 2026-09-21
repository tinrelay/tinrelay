require "./spec_helper"

describe "relationship closure and finite radio retune" do
  it "retains only acknowledged peers and restores a missed prior contact " +
     "explicitly through a hail" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      spool = Tinrelay::Spool.new(File.join(root, "alpha-inbox"))

      peers = {} of String => Tinrelay::Client
      %w(beta gamma delta).each do |ship|
        peer = TinrelaySpec.admit_contact(
          root, origin, ship, alpha
        )
        peer.send("steward@alpha", "establish #{ship}")
        event = alpha.radio_wait(spool, hold_seconds: 0)
        spool.routed(event.kind, event.source_id)
        peers[ship] = peer
      end

      alpha.rotate_owner.should eq(2)
      alpha.close_contact("beta").should eq(2)
      alpha.keyring.data.contact!("beta").blocked?.should be_true
      expect_raises(Tinrelay::Unauthorized, /blocked/) do
        alpha.send("steward@beta", "must not leave")
      end

      api.database.db.query_one(
        "SELECT state FROM relationships WHERE ship_a = 'alpha' AND ship_b = 'beta'",
        as: String
      ).should eq("transitioning")
      api.database.db.scalar(
        "SELECT COUNT(*) FROM relationship_transitions WHERE owner_ship = 'alpha'"
      ).as(Int64).should eq(2)

      # A newly submitted old-generation transmission is accepted opaquely but
      # cannot become relay payload once the positive relationship is closing.
      discarded = peers["beta"].send("steward@alpha", "old generation")
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", discarded.transmission_id
      ).as(Int64).should eq(0)

      # Gamma returns during the finite window. Its poll receives the public,
      # owner/prior-radio-authenticated chain and acknowledges the transition
      # before the next ordinary transmission is surfaced.
      gamma_spool = Tinrelay::Spool.new(File.join(root, "gamma-inbox"))
      gamma_events = Channel(Tinrelay::RadioEvent).new
      spawn do
        gamma_events.send(peers["gamma"].radio_wait(gamma_spool, hold_seconds: 1))
      end
      TinrelaySpec.eventually do
        api.database.db.query_one(
          "SELECT state FROM relationships WHERE ship_a = 'alpha' AND ship_b = 'gamma'",
          as: String
        ) == "active"
      end
      alpha.send("steward@gamma", "retune checkpoint")
      gamma_event = TinrelaySpec.receive(gamma_events)
      gamma_event.kind.should eq("transmission")
      gamma_spool.routed(gamma_event.kind, gamma_event.source_id)
      peers["gamma"].keyring.data.contact!("alpha")
        .radio_certificate.generation.should eq(2)
      peers["gamma"].keyring.data.contact!("alpha")
        .owner_generation.should eq(2)
      api.database.db.query_one(
        "SELECT state FROM relationships WHERE ship_a = 'alpha' AND ship_b = 'gamma'",
        as: String
      ).should eq("active")

      deadline = Time.utc.to_unix + Tinrelay::FALLBACK_LIFETIME_SECONDS + 1
      api.store.cleanup(deadline)
      api.database.db.query_one?(
        "SELECT state FROM relationships WHERE ship_a = 'alpha' AND ship_b = 'beta'",
        as: String
      ).should be_nil
      api.database.db.query_one?(
        "SELECT state FROM relationships WHERE ship_a = 'alpha' AND ship_b = 'delta'",
        as: String
      ).should be_nil
      api.database.db.query_one(
        "SELECT state FROM relationships WHERE ship_a = 'alpha' AND ship_b = 'gamma'",
        as: String
      ).should eq("active")
      api.database.db.scalar(
        "SELECT COUNT(*) FROM relationship_transitions"
      ).as(Int64).should eq(0)

      # The public certificate is not withheld. Alpha can hail the missed peer;
      # Delta verifies the continuity chain and sees it as a known prior contact,
      # but only Delta's explicit allow recreates positive relay state.
      hail = alpha.hail("delta")
      delta_spool = Tinrelay::Spool.new(File.join(root, "delta-inbox"))
      delta_event = peers["delta"].radio_wait(
        delta_spool, hold_seconds: 0
      )
      delta_event.kind.should eq("hail")
      delta_event.wrapper.should contain("Local contact state: known_prior_contact")
      peers["delta"].keyring.data.contact!("alpha")
        .radio_certificate.generation.should eq(2)
      api.database.db.query_one?(
        "SELECT state FROM relationships WHERE ship_a = 'alpha' AND ship_b = 'delta'",
        as: String
      ).should be_nil

      relay_hail_id = delta_spool.get(delta_event.kind, delta_event.source_id)
        .as(Tinrelay::HailSpoolRecord).hail_id
      relay_hail_id.should eq(hail.hail_id)
      peers["delta"].allow_contact(delta_event.source_id, delta_spool)
      api.database.db.query_one(
        "SELECT state FROM relationships WHERE ship_a = 'alpha' AND ship_b = 'delta'",
        as: String
      ).should eq("active")

      # A deliberately blocked prior ship's identical hail is consumed without
      # plaintext, spool evidence, or radio attention. The next valid item moves.
      blocked_hail = peers["beta"].hail("alpha")
      valid = peers["gamma"].send("steward@alpha", "still connected")
      delivered = alpha.radio_wait(spool, hold_seconds: 0)
      delivered.kind.should eq("transmission")
      spool.get(delivered.kind, delivered.source_id).as(Tinrelay::TransmissionSpoolRecord)
        .transmission_id.should eq(valid.transmission_id)
      spool.routed(delivered.kind, delivered.source_id)
      alpha.radio_poll(spool).should be_nil
      spool.list.any? do |record|
        record.is_a?(Tinrelay::HailSpoolRecord) &&
          record.hail_id == blocked_hail.hail_id
      end.should be_false
      api.database.db.query_one(
        "SELECT collected_at IS NOT NULL FROM hails WHERE id = ?",
        blocked_hail.hail_id, as: Int64
      ).should eq(1_i64)

      # Old receive private material exists only for the finite fallback window.
      alpha.keyring.data.radios.map(&.generation).should contain(1)
      alpha.keyring.prune_retired_radios!(deadline).should be_true
      alpha.keyring.data.radios.map(&.generation).should eq([2])
    end
  end

  it "rejects an owner-authorized retune with a wrong-sized radio signing key" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit(root, origin, "beta")
      TinrelaySpec.connect(root, alpha, beta)
      now = Time.utc.to_unix
      prior = alpha.keyring.data.radio!
      owner = alpha.keyring.owner
      encryption = Tinrelay::Crypto.box_keypair
      certificate = Tinrelay::ShipRadioCertificate.new(
        "alpha", 2,
        Tinrelay::Crypto.b64(Bytes.new(Tinrelay::Crypto::SIGN_PUBLIC_BYTES - 1)),
        Tinrelay::Crypto.b64(encryption.public_key), now, 1
      )
      certificate.owner_signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.sign(
          certificate.unsigned_bytes,
          Tinrelay::Crypto.unb64(owner.key.secret_key)
        )
      )
      prior_signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.sign(
          certificate.unsigned_bytes,
          Tinrelay::Crypto.unb64(prior.signing.secret_key)
        )
      )
      auth = Tinrelay::OwnerAuth.new("alpha", 1, 1_i64, now)
      closure = Tinrelay::RelationshipClose.new(
        "beta", [] of String, certificate, prior_signature, auth
      )
      auth.signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.sign(
          auth.signing_bytes("relationship.close", closure.payload),
          Tinrelay::Crypto.unb64(owner.key.secret_key)
        )
      )

      expect_raises(Tinrelay::Invalid, /radio signing public key length/) do
        api.store.close_relationship(closure, now)
      end
      api.database.db.scalar(
        "SELECT COUNT(*) FROM ship_radio_keys WHERE ship = 'alpha'"
      ).should eq(1)
      api.database.db.query_one(
        "SELECT state FROM ship_radio_keys WHERE ship = 'alpha' AND generation = 1",
        as: String
      ).should eq("active")
      api.database.db.query_one(
        "SELECT state FROM relationships WHERE ship_a = 'alpha' AND ship_b = 'beta'",
        as: String
      ).should eq("active")
    end
  end
end
