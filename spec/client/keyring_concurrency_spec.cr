require "../spec_helper"

class BlockingRadioRemote < Tinrelay::Remote
  getter entered = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)

  def post(path : String, body : String) : String
    return super unless path == "/v1/radio/wait"
    Tinrelay::RadioWaitRequest.from_json(body)
    entered.send(nil)
    release.receive
    Tinrelay::RadioWaitResponse.new.to_json
  end
end

class ConcurrentJoinRelay
  getter origin : String
  getter first_entered = Channel(Nil).new(1)
  getter release_first = Channel(Nil).new(1)

  def initialize(@api : Tinrelay::API)
    attempts = 0
    application = @api.handler
    @server = HTTP::Server.new do |context|
      if context.request.path == "/v1/join"
        attempts += 1
        if attempts == 1
          context.request.body.not_nil!.gets_to_end
          first_entered.send(nil)
          release_first.receive
          context.response.status_code = 403
          context.response.content_type = "application/json"
          context.response.print(%({"error":"registration_forbidden"}))
          next
        end
      end
      application.call(context)
    end
    address = @server.bind_tcp("127.0.0.1", 0)
    @origin = "http://127.0.0.1:#{address.port}"
    spawn { @server.listen }
    Fiber.yield
  end

  def close : Nil
    @server.close
  end
end

module KeyringConcurrencySpec
  def self.reload(client : Tinrelay::Client,
                  remote : Tinrelay::Remote? = nil) : Tinrelay::Client
    Tinrelay::Client.new(
      Tinrelay::Keyring.load(
        client.keyring.path, client.keyring.owner_path
      ),
      remote
    )
  end

  def self.close_one_of_beta_contacts(root : String, origin : String,
                                      beta : Tinrelay::Client) : Nil
    delta = TinrelaySpec.admit(root, origin, "delta")
    TinrelaySpec.connect(root, beta, delta)
    beta.close_contact("delta")
  end
end

describe "local ship identity concurrency" do
  it "rejects a whole-snapshot save after another process has advanced the file" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "ship.keyring")
    Tinrelay::Keyring.create(path, "http://127.0.0.1:1", "ship")
    first = Tinrelay::Keyring.load(path)
    stale = Tinrelay::Keyring.load(path)
    first.data.radio!.retire_after = 20_i64
    first.save
    stale.data.radio!.retire_after = 30_i64

    expect_raises(Tinrelay::Conflict, /changed since it was loaded/) do
      stale.save
    end
    Tinrelay::Keyring.load(path).data.radio!.retire_after.should eq(20_i64)
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "merges a returned peer retune with a contact allowed by another client" do
    TinrelaySpec.with_server do |root, origin, _api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit(root, origin, "beta")
      TinrelaySpec.connect(root, alpha, beta)
      stale_collector = KeyringConcurrencySpec.reload(alpha)

      gamma = TinrelaySpec.admit(root, origin, "gamma")
      gamma.hail("alpha")
      hail_spool = Tinrelay::Spool.new(File.join(root, "allow-inbox"))
      fresh = KeyringConcurrencySpec.reload(alpha)
      hail = fresh.radio_wait(hail_spool, hold_seconds: 0)
      fresh.allow_contact(hail.local_id, hail_spool)

      KeyringConcurrencySpec.close_one_of_beta_contacts(
        root, origin, beta
      )
      stale_collector.radio_poll(Tinrelay::Spool.new(File.join(root, "collector-inbox")))

      stored = Tinrelay::Keyring.load(alpha.keyring.path)
      stored.data.contact!("gamma").ship.should eq("gamma")
      stored.data.contact!("beta").radio_certificate.generation.should eq(2)
    end
  end

  it "honors a contact block written while a collector held an older snapshot" do
    TinrelaySpec.with_server do |root, origin, _api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit(root, origin, "beta")
      TinrelaySpec.connect(root, alpha, beta)
      stale_collector = KeyringConcurrencySpec.reload(alpha)
      beta.send("steward@alpha", "must not cross a newer local block")

      KeyringConcurrencySpec.reload(alpha).close_contact("beta")
      spool = Tinrelay::Spool.new(File.join(root, "blocked-inbox"))
      stale_collector.radio_poll(spool).should be_nil

      spool.list.should be_empty
      stored = Tinrelay::Keyring.load(alpha.keyring.path)
      stored.data.contact!("beta").blocked?.should be_true
      stored.data.active_radio_generation.should eq(2)
    end
  end

  it "merges a returned peer retune with a concurrent local owner rotation" do
    TinrelaySpec.with_server do |root, origin, _api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit(root, origin, "beta")
      TinrelaySpec.connect(root, alpha, beta)
      stale_collector = KeyringConcurrencySpec.reload(alpha)

      KeyringConcurrencySpec.reload(alpha).rotate_owner.should eq(2)
      KeyringConcurrencySpec.close_one_of_beta_contacts(
        root, origin, beta
      )
      stale_collector.radio_poll(Tinrelay::Spool.new(File.join(root, "owner-inbox")))

      stored = Tinrelay::Keyring.load(alpha.keyring.path)
      stored.data.owner_generation.should eq(2)
      stored.owner.generation.should eq(2)
      stored.data.contact!("beta").radio_certificate.generation.should eq(2)
    end
  end

  it "does not hold the ship identity lock while the radio request waits" do
    TinrelaySpec.with_server do |root, origin, _api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit(root, origin, "beta")
      TinrelaySpec.connect(root, alpha, beta)
      alpha.keyring.data.contact!("beta").blocked_at = Time.utc.to_unix
      alpha.keyring.save
      remote = BlockingRadioRemote.new(origin)
      collector = KeyringConcurrencySpec.reload(alpha, remote)
      finished = Channel(Nil).new(1)
      spawn do
        collector.radio_poll(Tinrelay::Spool.new(File.join(root, "wait-inbox")))
        finished.send(nil)
      end
      TinrelaySpec.receive(remote.entered)

      changed = Channel(Nil).new(1)
      spawn do
        KeyringConcurrencySpec.reload(alpha).unblock_contact("beta")
        changed.send(nil)
      end
      TinrelaySpec.receive(changed, 1.second)
      remote.release.send(nil)
      TinrelaySpec.receive(finished)
    end
  end

  it "does not let a losing same-path join delete a concurrently claimed identity" do
    root = TinrelaySpec.temporary_root
    config = Tinrelay::ServerConfig.new(
      database_path: File.join(root, "service.db")
    )
    api = Tinrelay::API.new(config)
    relay = ConcurrentJoinRelay.new(api)
    path = File.join(root, "shared.keyring")
    first_result = Channel(Exception?).new(1)
    spawn do
      begin
        Tinrelay::Client.join(path, relay.origin, "shared")
        first_result.send(nil)
      rescue ex
        first_result.send(ex)
      end
    end
    TinrelaySpec.receive(relay.first_entered)

    winner = Tinrelay::Client.join(path, relay.origin, "shared")
    relay.release_first.send(nil)
    TinrelaySpec.receive(first_result).should be_a(Tinrelay::RegistrationUnavailable)

    File.exists?(path).should be_true
    File.exists?("#{path}.owner").should be_true
    stored = Tinrelay::Keyring.load(path)
    stored.data.owner_public_key.should eq(winner.keyring.data.owner_public_key)
    api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(1_i64)
  ensure
    relay.try(&.close)
    api.try(&.close)
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
