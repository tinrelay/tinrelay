require "./spec_helper"

class RadioPollRemote < Tinrelay::Remote
  getter holds = [] of Int32
  getter acknowledgements = [] of String

  def initialize(origin : String,
                 @responses : Array(Tinrelay::RadioWaitResponse),
                 @ack_unavailable = false)
    super(origin)
  end

  def post(path : String, body : String) : String
    case path
    when "/v1/radio/wait"
      request = Tinrelay::RadioWaitRequest.from_json(body)
      holds << request.hold_seconds
      (@responses.shift? || raise "test radio sequence is empty").to_json
    when "/v1/transmissions/ack"
      acknowledgement = Tinrelay::TransmissionAck.from_json(body)
      acknowledgements << acknowledgement.transmission_id
      raise Tinrelay::Unavailable.new("synthetic relay outage") if @ack_unavailable
      %({"state":"acknowledged"})
    else
      super
    end
  end
end

describe "immediate radio polling" do
  it "releases a parked wait when its client connection closes" do
    TinrelaySpec.with_server(
      radio_wait_heartbeat_interval: 50.milliseconds
    ) do |root, origin, api|
      ship = Tinrelay::Client.join(
        File.join(root, "ship.keyring"), origin, "ship")
      request = TinrelaySpec.radio_wait_request(ship, 100)
      uri = URI.parse(origin)
      socket = TCPSocket.new(uri.host.not_nil!, uri.port.not_nil!)
      body = request.to_json
      socket << "POST /v1/radio/wait HTTP/1.1\r\n"
      socket << "Host: #{uri.host}:#{uri.port}\r\n"
      socket << "X-Tinrelay-Protocol: #{Tinrelay::PROTOCOL}\r\n"
      socket << "Content-Type: application/json\r\n"
      socket << "Content-Length: #{body.bytesize}\r\n\r\n"
      socket << body
      socket.flush
      TinrelaySpec.eventually { api.handoffs.waiting?("ship") }

      socket.close

      TinrelaySpec.eventually(500.milliseconds) do
        !api.handoffs.waiting?("ship")
      end
      api.metrics.render(api.store, api.handoffs)
        .should contain(%(tinrelay_radio_waits_total{outcome="disconnect"} 1))
    end
  end

  it "keeps a heartbeat response valid for the ordinary client" do
    TinrelaySpec.with_server(
      radio_wait_heartbeat_interval: 50.milliseconds
    ) do |root, origin, _api|
      ship = Tinrelay::Client.join(
        File.join(root, "ship.keyring"), origin, "ship")
      request = TinrelaySpec.radio_wait_request(ship, 1)

      response = Tinrelay::RadioWaitResponse.from_json(
        ship.remote.post("/v1/radio/wait", request.to_json)
      )

      response.empty?.should be_true
    end
  end

  it "accepts the signed 100-second maximum and rejects a longer hold" do
    TinrelaySpec.with_server do |root, origin, api|
      ship = Tinrelay::Client.join(
        File.join(root, "ship.keyring"), origin, "ship")

      accepted = TinrelaySpec.radio_wait_request(ship, 100)
      api.store.wait_once(accepted).empty?.should be_true

      rejected = TinrelaySpec.radio_wait_request(ship, 101)
      error = expect_raises(Tinrelay::Invalid) { api.store.wait_once(rejected) }
      error.message.should eq("wait hold must be between 0 and 100 seconds")
    end
  end

  it "uses the 100-second hold for ordinary radio waits and collection" do
    root = TinrelaySpec.temporary_root
    remote = RadioPollRemote.new(
      "http://127.0.0.1:1", [] of Tinrelay::RadioWaitResponse
    )
    keyring = Tinrelay::Keyring.create(
      File.join(root, "ship.keyring"), remote.origin, "ship")

    client = Tinrelay::Client.new(keyring, remote)
    spool = Tinrelay::Spool.new(File.join(root, "inbox"))
    expect_raises(Exception, "test radio sequence is empty") do
      client.radio_wait(spool)
    end
    expect_raises(Exception, "test radio sequence is empty") do
      client.radio_collect(spool)
    end
    remote.holds.should eq([100, 100])
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "surfaces durable local work even when relay cleanup is unavailable" do
    TinrelaySpec.with_server do |root, origin, _api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))
      beta.send("steward@alpha", "already safe at home")
      pending = alpha.radio_wait(spool, hold_seconds: 0)

      offline = RadioPollRemote.new(origin, [] of Tinrelay::RadioWaitResponse, true)
      replayed = Tinrelay::Client.new(alpha.keyring, offline)
        .radio_poll(spool)

      replayed.not_nil!.local_id.should eq(pending.local_id)
      offline.holds.should be_empty
      offline.acknowledgements.should be_empty
    end
  end

  it "lets radio wait resurface durable local work without the relay" do
    root = TinrelaySpec.temporary_root
    spool = Tinrelay::Spool.new(File.join(root, "inbox"))
    record = Tinrelay::RejectedTransmissionSpoolRecord.new(
      local_id: "tr_0123456789abcdef0123456789abcdef",
      received_at: 10_i64,
      relay_transmission_id: "11111111-1111-4111-8111-111111111111",
      rejection_reason: "unusable_envelope"
    )
    Tinrelay::AtomicPrivateFile.write(
      File.join(spool.pending, "#{record.local_id}.json"),
      record.to_pretty_json + "\n"
    )
    offline = RadioPollRemote.new(
      "http://127.0.0.1:1", [] of Tinrelay::RadioWaitResponse, true
    )
    keyring = Tinrelay::Keyring.create(
      File.join(root, "alpha.keyring"), "http://127.0.0.1:1", "alpha")

    event = Tinrelay::Client.new(keyring, offline)
      .radio_wait(spool, hold_seconds: 0)

    event.local_id.should eq(record.local_id)
    offline.holds.should be_empty
    offline.acknowledgements.should be_empty
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "collects immediately available relay work through the ordinary path" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))
      sent = beta.send("steward@alpha", "waiting at the repeater")

      event = alpha.radio_poll(spool).not_nil!

      event.kind.should eq("transmission")
      spool.get(event.local_id).as(Tinrelay::TransmissionSpoolRecord)
        .signed_transmission.body.should eq("waiting at the repeater")
      api.database.db.query_one(
        "SELECT state, ciphertext IS NULL FROM transmissions WHERE id = ?",
        sent.transmission_id, as: {String, Int64}
      ).should eq({"collected", 1_i64})
    end
  end

  it "collects new relay work while older local work remains unrouted" do
    TinrelaySpec.with_server do |root, origin, _api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", alpha
      )
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))
      beta.send("steward@alpha", "first local transmission")
      first = alpha.radio_wait(spool, hold_seconds: 0)
      beta.send("steward@alpha", "second relay transmission")

      second = alpha.radio_collect(spool, hold_seconds: 0)

      second.local_id.should_not eq(first.local_id)
      spool.next_unrouted.not_nil!.local_id.should eq(first.local_id)
      spool.list.count { |record| !record.routed }.should eq(2)
    end
  end

  it "makes exactly one zero-hold relay attempt and reports quiet" do
    TinrelaySpec.with_server do |root, origin, _api|
      ship = Tinrelay::Client.join(
        File.join(root, "ship.keyring"), origin, "ship")
      remote = RadioPollRemote.new(origin, [Tinrelay::RadioWaitResponse.new])
      client = Tinrelay::Client.new(ship.keyring, remote)

      client.radio_poll(Tinrelay::Spool.new(File.join(root, "inbox"))).should be_nil
      remote.holds.should eq([0])
    end
  end
end
