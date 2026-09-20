require "../spec_helper"

lib LibSQLite3
  alias TraceCallback = (UInt32, Void*, Void*, Void*) -> Int32

  fun trace_v2 = sqlite3_trace_v2(
    SQLite3, UInt32, TraceCallback, Void*,
  ) : Int32
end

module TinrelayStoreWriterConcurrencySpec
  TRACE_STATEMENT = 1_u32

  class CaptureRemote < Tinrelay::Remote
    getter captured : Tinrelay::SignedRelayEnvelope?

    def post(path : String, body : String) : String
      if path == "/v1/transmissions"
        @captured = Tinrelay::SignedRelayEnvelope.from_json(body)
        %({"state":"accepted"})
      else
        super
      end
    end
  end

  class StatementBarrier
    @entered = Channel(Nil).new(1)
    @release = Channel(Nil).new(1)
    @mutex = Mutex.new
    @waiting = true

    def initialize(@needle : String)
    end

    def observe(event : UInt32, raw_sql : Void*) : Int32
      return 0 unless event == TRACE_STATEMENT
      sql = String.new(raw_sql.as(UInt8*))
      wait = @mutex.synchronize do
        matches = @waiting && sql.includes?(@needle)
        @waiting = false if matches
        matches
      end
      if wait
        @entered.send(nil)
        @release.receive
      end
      0
    end

    def await : Nil
      TinrelaySpec.receive(@entered)
    end

    def release : Nil
      @release.send(nil)
    end
  end

  TRACE = ->(event : UInt32, context : Void*, _statement : Void*, sql : Void*) {
    Box(StatementBarrier).unbox(context).observe(event, sql)
  }

  def self.install_barrier(api : Tinrelay::API, barrier : StatementBarrier) : Nil
    api.database.db.setup_connection do |connection|
      context = Box.box(barrier)
      code = LibSQLite3.trace_v2(
        connection.as(SQLite3::Connection).to_unsafe,
        TRACE_STATEMENT,
        TRACE,
        context
      )
      raise "failed to install SQLite statement barrier" unless code == 0
    end
  end

  def self.dispatch(api : Tinrelay::API, path : String,
                    body = "", method = "POST") : Channel(Int32)
    finished = Channel(Int32).new(1)
    started = Channel(Nil).new(1)
    spawn do
      started.send(nil)
      request = HTTP::Request.new(
        method, path,
        HTTP::Headers{
          "Content-Type"        => "application/json",
          "X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s,
        },
        body
      )
      request.remote_address = Socket::IPAddress.new("127.0.0.1", 12_345)
      output = IO::Memory.new
      response = HTTP::Server::Response.new(output)
      api.handler.call(HTTP::Server::Context.new(request, response))
      response.close
      finished.send(response.status_code)
    end
    TinrelaySpec.receive(started)
    finished
  end

  def self.capture(sender : Tinrelay::Client, origin : String,
                   coordinate : String, body : String) : Tinrelay::SignedRelayEnvelope
    remote = CaptureRemote.new(origin)
    Tinrelay::Client.new(sender.keyring, remote).send(coordinate, body)
    remote.captured.not_nil!
  end

  def self.claim(ship : String) : Tinrelay::ShipClaim
    owner = Tinrelay::Crypto.signing_keypair
    signing = Tinrelay::Crypto.signing_keypair
    encryption = Tinrelay::Crypto.box_keypair
    now = Time.utc.to_unix
    certificate = Tinrelay::ShipRadioCertificate.new(
      ship, 1, Tinrelay::Crypto.b64(signing.public_key),
      Tinrelay::Crypto.b64(encryption.public_key), now, 1
    )
    certificate.owner_signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(certificate.unsigned_bytes, owner.secret_key)
    )
    Tinrelay::ShipClaim.new(ship, Tinrelay::Crypto.b64(owner.public_key), certificate)
  end
end

describe "Store writer admission" do
  it "keeps fallback insertion from invalidating an acknowledgement snapshot" do
    TinrelaySpec.with_server do |root, origin, api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit_contact(root, origin, "beta", alpha)
      first = beta.send("steward@alpha", "waiting for acknowledgement")
      second = TinrelayStoreWriterConcurrencySpec.capture(
        beta, origin, "steward@alpha", "concurrent fallback"
      )
      acknowledgement = Tinrelay::TransmissionAck.new(
        first.transmission_id,
        TinrelaySpec.radio_auth(
          alpha,
          "transmission.ack",
          Tinrelay::Canonical.fields(first.transmission_id)
        )
      )
      barrier = TinrelayStoreWriterConcurrencySpec::StatementBarrier.new(
        "UPDATE transmissions"
      )
      TinrelayStoreWriterConcurrencySpec.install_barrier(api, barrier)

      ack = TinrelayStoreWriterConcurrencySpec.dispatch(
        api, "/v1/transmissions/ack", acknowledgement.to_json
      )
      barrier.await
      read = TinrelayStoreWriterConcurrencySpec.dispatch(
        api, "/metrics", method: "GET"
      )
      TinrelaySpec.receive(read).should eq(200)
      fallback = TinrelayStoreWriterConcurrencySpec.dispatch(
        api, "/v1/transmissions", second.to_json
      )
      Fiber.yield
      inserted_while_ack_waited = api.database.db.query_one?(
        "SELECT 1 FROM transmissions WHERE id = ?", second.transmission_id, as: Int64
      )
      barrier.release

      ack_response = TinrelaySpec.receive(ack)
      fallback_response = TinrelaySpec.receive(fallback)
      ack_response.should eq(200)
      fallback_response.should eq(202)
      inserted_while_ack_waited.should be_nil
    end
  end

  it "keeps cleanup from invalidating a claim snapshot" do
    TinrelaySpec.with_server do |_root, _origin, api|
      api.database.db.exec(
        "INSERT INTO registration_events(accepted_at, source_bucket) VALUES (1, 'probe/32')"
      )
      barrier = TinrelayStoreWriterConcurrencySpec::StatementBarrier.new(
        "DELETE FROM registration_events"
      )
      TinrelayStoreWriterConcurrencySpec.install_barrier(api, barrier)
      claim = TinrelayStoreWriterConcurrencySpec.dispatch(
        api, "/v1/join", TinrelayStoreWriterConcurrencySpec.claim("claiming-ship").to_json
      )
      barrier.await
      cleanup = Channel(Exception?).new(1)
      spawn do
        begin
          api.store.cleanup(Tinrelay::Store::REGISTRATION_DAY_SECONDS + 2)
          cleanup.send(nil)
        rescue ex
          cleanup.send(ex)
        end
      end
      Fiber.yield
      cleaned_while_claim_waited = api.database.db.query_one?(
        "SELECT 1 FROM registration_events WHERE accepted_at = 1", as: Int64
      ).nil?
      barrier.release

      TinrelaySpec.receive(claim).should eq(201)
      TinrelaySpec.receive(cleanup).should be_nil
      cleaned_while_claim_waited.should be_false
    end
  end
end
