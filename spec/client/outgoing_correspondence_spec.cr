require "../spec_helper"

module TinrelayOutgoingCorrespondenceSpec
  class AcceptedRemote < Tinrelay::Remote
    def post(path : String, body : String) : String
      raise "unexpected path: #{path}" unless path == "/v1/transmissions"
      Tinrelay::SignedRelayEnvelope.from_json(body)
      %({"state":"accepted"})
    end
  end

  class UnknownRemote < Tinrelay::Remote
    def post(path : String, body : String) : String
      raise IO::Error.new("synthetic response loss")
    end
  end

  class TerminalRemote < Tinrelay::Remote
    def post(path : String, body : String) : String
      raise Tinrelay::Expired.new("synthetic terminal response")
    end
  end

  class WithdrawalUnknownRemote < AcceptedRemote
    def post(path : String, body : String) : String
      if path == "/v1/transmissions/withdraw"
        Tinrelay::TransmissionWithdrawal.from_json(body)
        raise IO::Error.new("synthetic withdrawal response loss")
      end
      super
    end
  end

  class OlderRelayRemote < AcceptedRemote
    def post(path : String, body : String) : String
      raise Tinrelay::NotFound.new("API route not found") if path == "/v1/transmissions/withdraw"
      super
    end
  end

  class WithdrawalLimitedRemote < AcceptedRemote
    def post(path : String, body : String) : String
      if path == "/v1/transmissions/withdraw"
        Tinrelay::TransmissionWithdrawal.from_json(body)
        raise Tinrelay::TransmissionLimited.new(17_i64)
      end
      super
    end
  end

  class BlockedSettlementRemote < AcceptedRemote
    def initialize(origin : String, @store : Tinrelay::OutgoingStore)
      super(origin)
    end

    def post(path : String, body : String) : String
      envelope = Tinrelay::SignedRelayEnvelope.from_json(body)
      Dir.mkdir(@store.sent_path(envelope.transmission_id))
      super
    end
  end

  def self.client(root : String, remote : Tinrelay::Remote) : Tinrelay::Client
    keyring = Tinrelay::Keyring.create(
      File.join(root, "keyring"), "http://127.0.0.1:1", "alpha"
    )
    Tinrelay::Client.new(keyring, remote)
  end
end

describe Tinrelay::OutgoingStore do
  it "moves one verified authored record from outbox to append-only sent evidence" do
    root = TinrelaySpec.temporary_root
    store = Tinrelay::OutgoingStore.new(File.join(root, "outgoing"), "alpha")
    client = TinrelayOutgoingCorrespondenceSpec.client(
      root, TinrelayOutgoingCorrespondenceSpec::AcceptedRemote.new("http://127.0.0.1:1")
    )

    envelope = client.send("@alpha", "exact authored words", "rowan", outgoing: store)

    store.list_outbox.should be_empty
    record = store.sent(envelope.transmission_id)
    record.transmission_id.should eq(envelope.transmission_id)
    record.signed_transmission.body.should eq("exact authored words")
    record.signed_relay_envelope.to_json.should eq(envelope.to_json)
    TinrelaySpec.assert_private_storage(store.root, 0o700)
    TinrelaySpec.assert_private_storage(store.outbox_directory, 0o700)
    TinrelaySpec.assert_private_storage(store.sent_directory, 0o700)
    TinrelaySpec.assert_private_storage(store.withdrawals_directory, 0o700)
    TinrelaySpec.assert_private_storage(store.sent_path(envelope.transmission_id), 0o600)
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "never lets a later terminal retry erase acceptance-unknown authored evidence" do
    root = TinrelaySpec.temporary_root
    store = Tinrelay::OutgoingStore.new(File.join(root, "outgoing"), "alpha")
    client = TinrelayOutgoingCorrespondenceSpec.client(
      root, TinrelayOutgoingCorrespondenceSpec::UnknownRemote.new("http://127.0.0.1:1")
    )

    failure = expect_raises(Tinrelay::AcceptanceUnknown) do
      client.send("@alpha", "possibly accepted", outgoing: store)
    end
    retained = store.outbox(failure.transmission_id)
    retained.signed_transmission.body.should eq("possibly accepted")

    reloaded = Tinrelay::OutgoingStore.new(store.root, "alpha")
    terminal = Tinrelay::Client.new(
      client.keyring,
      TinrelayOutgoingCorrespondenceSpec::TerminalRemote.new("http://127.0.0.1:1")
    )
    expect_raises(Tinrelay::Expired) do
      terminal.retry(reloaded, failure.transmission_id)
    end
    reloaded.outbox(failure.transmission_id).to_json.should eq(retained.to_json)
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "removes a newly created record after a definitive initial rejection" do
    root = TinrelaySpec.temporary_root
    store = Tinrelay::OutgoingStore.new(File.join(root, "outgoing"), "alpha")
    client = TinrelayOutgoingCorrespondenceSpec.client(
      root, TinrelayOutgoingCorrespondenceSpec::TerminalRemote.new("http://127.0.0.1:1")
    )

    expect_raises(Tinrelay::Expired) do
      client.send("@alpha", "definitely rejected", outgoing: store)
    end
    store.list_outbox.should be_empty
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "verifies sent evidence without the current keyring or retired secret keys" do
    root = TinrelaySpec.temporary_root
    store = Tinrelay::OutgoingStore.new(File.join(root, "outgoing"), "alpha")
    client = TinrelayOutgoingCorrespondenceSpec.client(
      root, TinrelayOutgoingCorrespondenceSpec::AcceptedRemote.new("http://127.0.0.1:1")
    )
    envelope = client.send("@alpha", "durable public proof", outgoing: store)

    File.delete(client.keyring.path)
    File.delete(client.keyring.owner_path)
    reloaded = Tinrelay::OutgoingStore.new(store.root, "alpha").sent(
      envelope.transmission_id
    )
    reloaded.signed_transmission.body.should eq("durable public proof")
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "adds one deterministic marker without rewriting sent history" do
    root = TinrelaySpec.temporary_root
    store = Tinrelay::OutgoingStore.new(File.join(root, "outgoing"), "alpha")
    client = TinrelayOutgoingCorrespondenceSpec.client(
      root, TinrelayOutgoingCorrespondenceSpec::AcceptedRemote.new("http://127.0.0.1:1")
    )
    envelope = client.send("@alpha", "append-only", outgoing: store)
    transmission_id = envelope.transmission_id
    before = File.read(store.sent_path(transmission_id))

    store.mark_withdrawal(transmission_id)
    marker = File.read(store.withdrawal_path(transmission_id))
    store.mark_withdrawal(transmission_id)

    File.read(store.sent_path(transmission_id)).should eq(before)
    File.read(store.withdrawal_path(transmission_id)).should eq(marker)
    TinrelaySpec.assert_private_storage(store.withdrawal_path(transmission_id), 0o600)
    JSON.parse(marker).as_h.keys.sort.should eq(%w(format transmission_id))
    store.withdrawal_requested?(transmission_id).should be_true
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "keeps accepted outbox evidence recoverable when the local sent move fails" do
    root = TinrelaySpec.temporary_root
    store = Tinrelay::OutgoingStore.new(File.join(root, "outgoing"), "alpha")
    remote = TinrelayOutgoingCorrespondenceSpec::BlockedSettlementRemote.new(
      "http://127.0.0.1:1", store
    )
    client = TinrelayOutgoingCorrespondenceSpec.client(root, remote)

    failure = expect_raises(Tinrelay::Error, /accepted.*could not be moved/) do
      client.send("@alpha", "accepted before local failure", outgoing: store)
    end
    record = store.list_outbox.first
    record.signed_transmission.body.should eq("accepted before local failure")
    FileUtils.rm_r(store.sent_path(record.transmission_id))

    retrying = Tinrelay::Client.new(
      client.keyring,
      TinrelayOutgoingCorrespondenceSpec::AcceptedRemote.new("http://127.0.0.1:1")
    )
    retrying.retry(store, record.transmission_id)
    store.list_outbox.should be_empty
    store.sent(record.transmission_id).signed_transmission.body
      .should eq("accepted before local failure")
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "does not write a withdrawal marker for ambiguity or an unsupported relay" do
    root = TinrelaySpec.temporary_root
    store = Tinrelay::OutgoingStore.new(File.join(root, "outgoing"), "alpha")
    client = TinrelayOutgoingCorrespondenceSpec.client(
      root, TinrelayOutgoingCorrespondenceSpec::AcceptedRemote.new("http://127.0.0.1:1")
    )
    envelope = client.send("@alpha", "still sent", outgoing: store)
    transmission_id = envelope.transmission_id

    ambiguous = Tinrelay::Client.new(
      client.keyring,
      TinrelayOutgoingCorrespondenceSpec::WithdrawalUnknownRemote.new(
        "http://127.0.0.1:1"
      )
    )
    failure = expect_raises(Tinrelay::WithdrawalAcceptanceUnknown) do
      ambiguous.withdraw(store, transmission_id)
    end
    failure.message.to_s.should contain("withdraw #{transmission_id}")
    store.withdrawal_requested?(transmission_id).should be_false

    unsupported = Tinrelay::Client.new(
      client.keyring,
      TinrelayOutgoingCorrespondenceSpec::OlderRelayRemote.new("http://127.0.0.1:1")
    )
    expect_raises(Tinrelay::UnsupportedFeature, /does not support/) do
      unsupported.withdraw(store, transmission_id)
    end
    store.withdrawal_requested?(transmission_id).should be_false
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "gives a rate-limited withdrawal its own truthful retry command" do
    root = TinrelaySpec.temporary_root
    store = Tinrelay::OutgoingStore.new(File.join(root, "outgoing"), "alpha")
    client = TinrelayOutgoingCorrespondenceSpec.client(
      root, TinrelayOutgoingCorrespondenceSpec::AcceptedRemote.new("http://127.0.0.1:1")
    )
    envelope = client.send("@alpha", "still sent", outgoing: store)
    transmission_id = envelope.transmission_id
    limited = Tinrelay::Client.new(
      client.keyring,
      TinrelayOutgoingCorrespondenceSpec::WithdrawalLimitedRemote.new(
        "http://127.0.0.1:1"
      )
    )

    failure = expect_raises(Tinrelay::WithdrawalLimited) do
      limited.withdraw(store, transmission_id)
    end
    failure.retry_after_seconds.should eq(17)
    failure.message.to_s.should contain("withdraw #{transmission_id}")
    failure.message.to_s.should_not contain("outbox retry")
    store.withdrawal_requested?(transmission_id).should be_false
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "keeps an expired acceptance-unknown record inspectable but nonretryable" do
    root = TinrelaySpec.temporary_root
    store = Tinrelay::OutgoingStore.new(File.join(root, "outgoing"), "alpha")
    client = TinrelayOutgoingCorrespondenceSpec.client(
      root, TinrelayOutgoingCorrespondenceSpec::UnknownRemote.new("http://127.0.0.1:1")
    )

    failure = expect_raises(Tinrelay::AcceptanceUnknown) do
      client.send("@alpha", "expired but authored", expires_in: 0, outgoing: store)
    end
    store.outbox(failure.transmission_id).signed_transmission.body
      .should eq("expired but authored")
    store.retryable?(store.outbox(failure.transmission_id)).should be_false
    expect_raises(Tinrelay::Expired, /no longer retryable/) do
      client.retry(store, failure.transmission_id)
    end
    store.outbox(failure.transmission_id).signed_transmission.body
      .should eq("expired but authored")
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "cannot retry or withdraw another local ship's outgoing evidence" do
    root = TinrelaySpec.temporary_root
    store = Tinrelay::OutgoingStore.new(File.join(root, "outgoing"), "alpha")
    alpha = TinrelayOutgoingCorrespondenceSpec.client(
      root, TinrelayOutgoingCorrespondenceSpec::UnknownRemote.new("http://127.0.0.1:1")
    )
    unknown = expect_raises(Tinrelay::AcceptanceUnknown) do
      alpha.send("@alpha", "alpha unknown", outgoing: store)
    end
    beta_keyring = Tinrelay::Keyring.create(
      File.join(root, "beta.keyring"), "http://127.0.0.1:1", "beta"
    )
    beta = Tinrelay::Client.new(
      beta_keyring,
      TinrelayOutgoingCorrespondenceSpec::AcceptedRemote.new("http://127.0.0.1:1")
    )
    expect_raises(Tinrelay::Unauthorized, /another local ship/) do
      beta.retry(store, unknown.transmission_id)
    end
    store.outbox(unknown.transmission_id).signed_transmission.body.should eq("alpha unknown")

    accepted_alpha = Tinrelay::Client.new(
      alpha.keyring,
      TinrelayOutgoingCorrespondenceSpec::AcceptedRemote.new("http://127.0.0.1:1")
    )
    accepted = accepted_alpha.send("@alpha", "alpha sent", outgoing: store)
    expect_raises(Tinrelay::Unauthorized, /another local ship/) do
      beta.withdraw(store, accepted.transmission_id)
    end
    store.withdrawal_requested?(accepted.transmission_id).should be_false
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "isolates corrupt records and verifies old authorship after owner rotation" do
    TinrelaySpec.with_server do |root, origin, _api|
      store = Tinrelay::OutgoingStore.new(File.join(root, "outgoing"), "alpha")
      client = Tinrelay::Client.join(File.join(root, "alpha.keyring"), origin, "alpha")
      first = client.send("@alpha", "before rotation", outgoing: store)
      first_id = first.transmission_id
      old_owner = store.sent(first_id).authoring_owner.generation

      client.rotate_owner
      client.keyring.data.owner_generation.should be > old_owner
      store.sent(first_id).signed_transmission.body.should eq("before rotation")
      second = client.send("@alpha", "after rotation", outgoing: store)
      second_id = second.transmission_id
      store.sent(second_id).authoring_owner.generation.should eq(old_owner)
      store.sent(second_id).signed_transmission.body.should eq("after rotation")

      corrupt_id = "ffffffff-ffff-4fff-8fff-ffffffffffff"
      corrupt_path = store.sent_path(corrupt_id)
      Tinrelay::AtomicPrivateFile.write(corrupt_path, "not json")
      preserved = File.read(corrupt_path)
      store.list_sent.map(&.transmission_id).sort.should eq([first_id, second_id].sort)
      File.read(corrupt_path).should eq(preserved)
    end
  end

  it "cannot recall correspondence already durably collected by the recipient" do
    TinrelaySpec.with_server do |root, origin, _api|
      alpha = Tinrelay::Client.join(File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(root, origin, "beta", alpha)
      outgoing = Tinrelay::OutgoingStore.new(File.join(root, "outgoing"), "beta")
      envelope = beta.send("steward@alpha", "already collected", outgoing: outgoing)
      spool = Tinrelay::Spool.new(File.join(root, "alpha-inbox"))
      event = alpha.radio_wait(spool, hold_seconds: 0)
      received = spool.get(event.kind, event.source_id).as(Tinrelay::TransmissionSpoolRecord)
      received.signed_transmission.body.should eq("already collected")

      beta.withdraw(outgoing, envelope.transmission_id)
      outgoing.withdrawal_requested?(envelope.transmission_id).should be_true
      spool.get(event.kind, event.source_id).as(Tinrelay::TransmissionSpoolRecord)
        .signed_transmission.body.should eq("already collected")
    end
  end
end
