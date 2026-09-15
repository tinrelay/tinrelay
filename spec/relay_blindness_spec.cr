require "./spec_helper"

class AcceptThenDropRemote < Tinrelay::Remote
  getter saw_preserved_envelope : Bool = false

  def initialize(origin : String, @store : Tinrelay::Store,
                 @outbox_directory : String)
    super(origin)
    @dropped = false
  end

  def post(path : String, body : String) : String
    if path == "/v1/transmissions" && !@dropped
      envelope = Tinrelay::SignedRelayEnvelope.from_json(body)
      @saw_preserved_envelope = File.exists?(
        File.join(@outbox_directory, "#{envelope.transmission_id}.json")
      )
      @store.accept(envelope)
      @dropped = true
      raise IO::Error.new("synthetic response loss")
    end
    super
  end
end

describe "the socially blind repeater boundary" do
  it "retains one exact encrypted envelope when acceptance is unknown" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      outbox = Tinrelay::Outbox.new(File.join(root, "outbox"))
      unreliable_remote = AcceptThenDropRemote.new(origin, api.store, outbox.directory)
      unreliable = Tinrelay::Client.new(beta.keyring, unreliable_remote)

      failure = expect_raises(Tinrelay::AcceptanceUnknown, /acceptance is unknown/) do
        unreliable.send("steward@alpha", "response may have been lost", outbox: outbox)
      end
      pending = outbox.list
      pending.size.should eq(1)
      pending[0].transmission_id.should eq(failure.transmission_id)
      unreliable_remote.saw_preserved_envelope.should be_true
      File.info(File.join(root, "outbox")).permissions.value.should eq(0o700)
      path = File.join(root, "outbox", "#{failure.transmission_id}.json")
      File.info(path).permissions.value.should eq(0o600)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", failure.transmission_id
      ).as(Int64).should eq(1)

      retried = beta.retry(outbox, failure.transmission_id)
      retried.submission_evidence[:state].should eq("accepted")
      outbox.list.should be_empty

      spool = Tinrelay::Spool.new(File.join(root, "inbox"))
      event = alpha.radio_wait(spool, hold_seconds: 0)
      event.local_id.should_not be_empty

      # Collection and relay payload erasure do not change sender evidence.
      response = beta.remote.post("/v1/transmissions", retried.to_json)
      JSON.parse(response)["state"].as_s.should eq("accepted")

      changed = Tinrelay::SignedRelayEnvelope.from_json(retried.to_json)
      changed.ciphertext = Tinrelay::Crypto.b64(Tinrelay::Crypto.random(48))
      error = expect_raises(Tinrelay::Conflict) do
        beta.remote.post("/v1/transmissions", changed.to_json)
      end
      error.message.should eq("relay reported a state conflict")
    end
  end

  it "allows signed self/contact inspection without a public ship-name oracle" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")

      gamma = Tinrelay::Client.join(
        File.join(root, "gamma.keyring"), origin, "gamma")

      unrelated = expect_raises(Tinrelay::NotFound) { gamma.who("alpha") }
      nonexistent = expect_raises(Tinrelay::NotFound) { gamma.who("not-claimed") }
      unrelated.message.should eq(nonexistent.message)

      headers = HTTP::Headers{"X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s}
      HTTP::Client.get("#{origin}/v1/who/alpha", headers).status_code.should eq(404)
      HTTP::Client.get("#{origin}/v1/status/alpha", headers).status_code.should eq(404)

      TinrelaySpec.connect(root, alpha, gamma)
      JSON.parse(gamma.who("alpha"))["ship"].as_s.should eq("alpha")
      JSON.parse(alpha.who("gamma"))["ship"].as_s.should eq("gamma")
    end
  end
end
