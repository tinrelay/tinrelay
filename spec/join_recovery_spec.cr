require "./spec_helper"

class JoinRecoveryRelay
  getter origin : String
  getter join_bodies = [] of String

  def initialize(@api : Tinrelay::API, @commit_first : Bool,
                 @first_status = 503,
                 @first_body = %({"error":"unavailable"}),
                 @first_headers = HTTP::Headers.new)
    @join_attempts = 0
    application = @api.handler
    @server = HTTP::Server.new do |context|
      if context.request.path == "/v1/join" && @join_attempts == 0
        @join_attempts += 1
        body = context.request.body.not_nil!.gets_to_end
        @join_bodies << body
        if @commit_first
          claim = Tinrelay::ShipClaim.from_json(body)
          TinrelaySpec.claim_directly(@api.store, @api.store.prepare_claim(claim))
        end
        context.response.status_code = @first_status
        context.response.content_type = "application/json"
        @first_headers.each { |key, values| context.response.headers[key] = values }
        context.response.print(@first_body)
      else
        if context.request.path == "/v1/join"
          body = context.request.body.not_nil!.gets_to_end
          @join_bodies << body
          context.request.body = IO::Memory.new(body)
        end
        application.call(context)
      end
    end
    address = @server.bind_tcp("127.0.0.1", 0)
    @origin = "http://127.0.0.1:#{address.port}"
    spawn { @server.listen }
  end

  def close : Nil
    @server.close
  end
end

module JoinRecoverySpec
  def self.with_relay(commit_first : Bool, first_status = 503,
                      first_body = %({"error":"unavailable"}),
                      first_headers = HTTP::Headers.new, &)
    root = TinrelaySpec.temporary_root
    template = File.expand_path("../templates/common-bootstrap.md", __DIR__)
    config = Tinrelay::ServerConfig.new(
      database_path: File.join(root, "service.db"),
      bootstrap_template: template
    )
    api = Tinrelay::API.new(config)
    relay = JoinRecoveryRelay.new(
      api, commit_first, first_status, first_body, first_headers
    )
    yield root, relay, api
  ensure
    relay.try(&.close)
    api.try(&.close)
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  def self.claim(api : Tinrelay::API, keyring : Tinrelay::Keyring) : Nil
    claim = Tinrelay::ShipClaim.new(
      keyring.data.ship,
      keyring.data.owner_public_key,
      keyring.data.radio!.certificate
    )
    TinrelaySpec.claim_directly(api.store, api.store.prepare_claim(claim))
  end
end

describe "ship claim recovery" do
  it "removes provisional identity after a definite registration-policy denial" do
    root = TinrelaySpec.temporary_root
    server = HTTP::Server.new do |context|
      context.response.status_code = 403
      context.response.content_type = "application/json"
      context.response.print(%({"error":"registration_forbidden"}))
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    path = File.join(root, "closed.keyring")
    owner_path = "#{path}.owner"
    begin
      expect_raises(Tinrelay::RegistrationUnavailable) do
        Tinrelay::Client.join(
          path, "http://127.0.0.1:#{address.port}", "closed")
      end
      File.exists?(path).should be_false
      File.exists?(owner_path).should be_false
    ensure
      server.close
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  it "preserves provisional identity when a committed response becomes a foreign 403" do
    JoinRecoverySpec.with_relay(
      commit_first: true, first_status: 403,
      first_body: %({"error":"foreign"})
    ) do |root, relay, api|
      path = File.join(root, "foreign.keyring")
      owner_path = "#{path}.owner"

      expect_raises(Tinrelay::Unauthorized) do
        Tinrelay::Client.join(
          path, relay.origin, "foreign-response")
      end

      File.exists?(path).should be_true
      File.exists?(owner_path).should be_true
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(1_i64)
    end
  end

  it "preserves provisional identity when a committed response becomes a generic 429" do
    headers = HTTP::Headers{"Retry-After" => "37"}
    JoinRecoverySpec.with_relay(
      commit_first: true, first_status: 429,
      first_body: %({"error":"busy"}), first_headers: headers
    ) do |root, relay, api|
      path = File.join(root, "foreign-429.keyring")
      owner_path = "#{path}.owner"

      error = expect_raises(Tinrelay::Unavailable) do
        Tinrelay::Client.join(
          path, relay.origin, "foreign-429")
      end

      error.should_not be_a(Tinrelay::RegistrationLimited)
      File.exists?(path).should be_true
      File.exists?(owner_path).should be_true
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(1_i64)
    end
  end

  it "keeps the original keys and recovers a committed claim after a lost response" do
    JoinRecoverySpec.with_relay(commit_first: true) do |root, relay, api|
      path = File.join(root, "lost.keyring")
      owner_path = "#{path}.owner"

      expect_raises(Tinrelay::Unavailable) do
        Tinrelay::Client.join(path, relay.origin, "lost")
      end
      keyring_bytes = File.read(path)
      owner_bytes = File.read(owner_path)
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(1)

      recovered = Tinrelay::Client.join(path, relay.origin, "lost")

      recovered.keyring.data.ship.should eq("lost")
      File.read(path).should eq(keyring_bytes)
      File.read(owner_path).should eq(owner_bytes)
      relay.join_bodies.size.should eq(1)
    end
  end

  it "retries the identical claim when the ambiguous attempt was not committed" do
    JoinRecoverySpec.with_relay(commit_first: false) do |root, relay, api|
      path = File.join(root, "retry.keyring")
      owner_path = "#{path}.owner"

      expect_raises(Tinrelay::Unavailable) do
        Tinrelay::Client.join(path, relay.origin, "retry")
      end
      keyring_bytes = File.read(path)
      owner_bytes = File.read(owner_path)
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(0)

      Tinrelay::Client.join(path, relay.origin, "retry")

      relay.join_bodies.size.should eq(2)
      relay.join_bodies[1].should eq(relay.join_bodies[0])
      File.read(path).should eq(keyring_bytes)
      File.read(owner_path).should eq(owner_bytes)
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(1)
    end
  end

  it "preserves provisional evidence when another identity owns the remote name" do
    JoinRecoverySpec.with_relay(commit_first: false) do |root, relay, api|
      path = File.join(root, "mismatch.keyring")
      owner_path = "#{path}.owner"

      expect_raises(Tinrelay::Unavailable) do
        Tinrelay::Client.join(path, relay.origin, "mismatch")
      end
      keyring_bytes = File.read(path)
      owner_bytes = File.read(owner_path)
      other = Tinrelay::Keyring.create(
        File.join(root, "other.keyring"), relay.origin, "mismatch")
      JoinRecoverySpec.claim(api, other)

      expect_raises(Tinrelay::Conflict) do
        Tinrelay::Client.join(path, relay.origin, "mismatch")
      end

      File.read(path).should eq(keyring_bytes)
      File.read(owner_path).should eq(owner_bytes)
    end
  end
end
