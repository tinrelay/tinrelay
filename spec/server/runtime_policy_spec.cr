require "../spec_helper"

module TinrelayRuntimePolicySpec
  class GatedBody < IO
    getter entered = Channel(Nil).new(1)
    getter release = Channel(Nil).new(1)

    def initialize(body : String)
      @body = IO::Memory.new(body)
      @waiting = true
    end

    def read(slice : Bytes) : Int32
      if @waiting
        @waiting = false
        entered.send(nil)
        release.receive
      end
      @body.read(slice)
    end

    def write(slice : Bytes) : NoReturn
      raise IO::Error.new("read only")
    end
  end

  def self.server_config(root : String, configuration_path : String) : Tinrelay::ServerConfig
    Tinrelay::ServerConfig.new(
      database_path: File.join(root, "service.db"),
      configuration_path: configuration_path
    )
  end

  def self.write_defaults(path : String) : Nil
    File.write(path, "{}")
  end

  def self.write_complete(path : String, exclude = [] of String) : Nil
    File.write(path, {
      registration: {
        global_hour: 301, global_day: 1001,
        per_source_hour: 5, per_source_day: 6,
        deny_cidrs: ["192.0.2.0/24", "2001:db8::/32"],
        exclude: exclude,
      },
      client_address: {
        mode:                  "trusted_proxy",
        trusted_ingress_cidrs: ["198.51.100.0/24"],
      },
      logging: {requests: false},
    }.to_json)
  end

  def self.write_closed(path : String) : Nil
    File.write(path, {
      registration: {
        global_hour: 0, global_day: 0,
        per_source_hour: 0, per_source_day: 0,
      },
    }.to_json)
  end

  def self.write_open_policy(path : String) : Nil
    File.write(path, {
      registration: {
        global_hour: 301, global_day: 1001,
        per_source_hour: 5, per_source_day: 6,
      },
    }.to_json)
  end

  def self.claim(api : Tinrelay::API, ship : String) : Nil
    TinrelaySpec.claim_directly(api.store, prepared(api, ship))
  end

  def self.prepared(api : Tinrelay::API,
                    ship : String) : Tinrelay::PreparedShipClaim
    api.store.prepare_claim(TinrelaySpec.valid_claim(ship))
  end

  def self.claim_body(ship : String) : String
    TinrelaySpec.valid_claim(ship).to_json
  end
end

describe "tinrelayd runtime policy" do
  it "accepts zero as explicit registration closure and rejects negative allowances" do
    Tinrelay::RegistrationAllowances.new(0, 0, 0, 0).closed?.should be_true
    Tinrelay::RegistrationAllowances.new(1, 1, 1, 1).closed?.should be_false
    expect_raises(Tinrelay::Invalid, /non-negative/) do
      Tinrelay::RegistrationAllowances.new(-1, 1, 1, 1)
    end
  end

  it "gives an empty configuration the exact policy defaults" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "tinrelayd.json")
    TinrelayRuntimePolicySpec.write_defaults(path)
    api = Tinrelay::API.new(TinrelayRuntimePolicySpec.server_config(root, path))
    begin
      snapshot = api.runtime_snapshot
      allowances = snapshot.registration_allowances
      allowances.global_hour.should eq(300)
      allowances.global_day.should eq(1000)
      allowances.per_source_hour.should eq(4)
      allowances.per_source_day.should eq(4)
      snapshot.registration_deny_cidrs.should be_empty
      snapshot.client_address_policy.mode.should eq(Tinrelay::ClientAddressMode::Direct)
      snapshot.client_address_policy.trusted_ingress_cidrs.should be_empty
      snapshot.request_logging?.should be_true
    ensure
      api.close
      FileUtils.rm_r(root)
    end
  end

  it "bounds exclusion names before registry validation" do
    names = Array.new(256) { |index| "ship-#{index}" }
    registration = Tinrelay::TinrelaydConfig::Registration.from_json({
      exclude: names,
    }.to_json)
    config = Tinrelay::TinrelaydConfig.new(registration)
    config.rate_limit_exclusions.should eq(names)

    registration = Tinrelay::TinrelaydConfig::Registration.from_json({
      exclude: names + ["ship-256"],
    }.to_json)
    config = Tinrelay::TinrelaydConfig.new(registration)
    expect_raises(Tinrelay::Invalid, /too many/) do
      config.rate_limit_exclusions
    end
  end

  it "publishes one complete valid snapshot and retains it after invalid reloads" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "tinrelayd.json")
    TinrelayRuntimePolicySpec.write_defaults(path)
    api = Tinrelay::API.new(TinrelayRuntimePolicySpec.server_config(root, path))
    begin
      prior = api.runtime_snapshot
      TinrelayRuntimePolicySpec.write_complete(path)
      api.reload_configuration
      current = api.runtime_snapshot
      current.same?(prior).should be_false
      allowances = current.registration_allowances
      {allowances.global_hour, allowances.global_day}.should eq({301, 1001})
      {allowances.per_source_hour, allowances.per_source_day}.should eq({5, 6})
      current.registration_deny_cidrs.size.should eq(2)
      policy = current.client_address_policy
      policy.mode.should eq(Tinrelay::ClientAddressMode::TrustedProxy)
      policy.trusted_ingress_cidrs.size.should eq(1)
      current.request_logging?.should be_false

      File.write(path, {
        client_address: {
          mode: "trusted_proxy", trusted_ingress_cidrs: [] of String,
        },
      }.to_json)
      expect_raises(Tinrelay::Invalid) { api.reload_configuration }
      api.runtime_snapshot.same?(current).should be_true

      File.delete(path)
      expect_raises(Tinrelay::Invalid) { api.reload_configuration }
      api.runtime_snapshot.same?(current).should be_true
    ensure
      api.close
      FileUtils.rm_r(root)
    end
  end

  it "publishes reload only outside an active claim commit" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "tinrelayd.json")
    TinrelayRuntimePolicySpec.write_defaults(path)
    api = Tinrelay::API.new(TinrelayRuntimePolicySpec.server_config(root, path))
    begin
      prior = api.runtime_snapshot
      entered = Channel(Nil).new(1)
      release = Channel(Nil).new(1)
      claim_done = Channel(Exception?).new(1)
      reload_done = Channel(Exception?).new(1)
      prepared = TinrelayRuntimePolicySpec.prepared(api, "before-closure")
      spawn do
        begin
          api.store.claim(
            prepared, TinrelaySpec::TEST_SOURCE_BUCKET,
            prior.registration_allowances,
            policy_current: -> do
              entered.send(nil)
              release.receive
              true
            end
          )
          claim_done.send(nil)
        rescue ex
          claim_done.send(ex)
        end
      end
      TinrelaySpec.receive(entered)

      TinrelayRuntimePolicySpec.write_closed(path)
      spawn do
        begin
          api.reload_configuration
          reload_done.send(nil)
        rescue ex
          reload_done.send(ex)
        end
      end
      Fiber.yield
      api.runtime_snapshot.same?(prior).should be_true

      release.send(nil)
      TinrelaySpec.receive(claim_done).should be_nil
      TinrelaySpec.receive(reload_done).should be_nil
      api.runtime_snapshot.same?(prior).should be_false
      api.runtime_snapshot.registration_allowances.closed?.should be_true
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(1_i64)
    ensure
      api.try(&.close)
      FileUtils.rm_r(root) if root && Dir.exists?(root)
    end
  end

  it "rejects a delayed claim whose captured policy was replaced" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "tinrelayd.json")
    TinrelayRuntimePolicySpec.write_defaults(path)
    api = Tinrelay::API.new(TinrelayRuntimePolicySpec.server_config(root, path))
    begin
      body = TinrelayRuntimePolicySpec::GatedBody.new(
        TinrelayRuntimePolicySpec.claim_body("stale-policy")
      )
      request = HTTP::Request.new(
        "POST", "/v1/join",
        HTTP::Headers{
          "Content-Type"        => "application/json",
          "X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s,
        },
        body
      )
      request.remote_address = Socket::IPAddress.new("127.0.0.1", 12_345)
      output = IO::Memory.new
      response = HTTP::Server::Response.new(output)
      context = HTTP::Server::Context.new(request, response)
      handled = Channel(Exception?).new(1)
      spawn do
        begin
          api.handler.call(context)
          response.close
          handled.send(nil)
        rescue ex
          handled.send(ex)
        end
      end
      TinrelaySpec.receive(body.entered)

      TinrelayRuntimePolicySpec.write_closed(path)
      api.reload_configuration
      body.release.send(nil)
      TinrelaySpec.receive(handled).should be_nil

      response.status_code.should eq(403)
      response.headers["Retry-After"]?.should be_nil
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(0_i64)
      api.database.db.scalar("SELECT COUNT(*) FROM registration_events").should eq(0_i64)
      metrics = api.metrics.render(api.store, api.handoffs)
      metrics.should contain(
        %(tinrelay_registrations_total{outcome="closed"} 1)
      )
    ensure
      api.try(&.close)
      FileUtils.rm_r(root) if root && Dir.exists?(root)
    end
  end

  it "counts a nonspecific stale-policy rejection as policy changed" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "tinrelayd.json")
    TinrelayRuntimePolicySpec.write_defaults(path)
    api = Tinrelay::API.new(TinrelayRuntimePolicySpec.server_config(root, path))
    begin
      body = TinrelayRuntimePolicySpec::GatedBody.new(
        TinrelayRuntimePolicySpec.claim_body("stale-policy-metric")
      )
      request = HTTP::Request.new(
        "POST", "/v1/join",
        HTTP::Headers{
          "Content-Type"        => "application/json",
          "X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s,
        },
        body
      )
      request.remote_address = Socket::IPAddress.new("127.0.0.1", 12_345)
      output = IO::Memory.new
      response = HTTP::Server::Response.new(output)
      context = HTTP::Server::Context.new(request, response)
      handled = Channel(Exception?).new(1)
      spawn do
        begin
          api.handler.call(context)
          response.close
          handled.send(nil)
        rescue ex
          handled.send(ex)
        end
      end
      TinrelaySpec.receive(body.entered)

      TinrelayRuntimePolicySpec.write_open_policy(path)
      api.reload_configuration
      body.release.send(nil)
      TinrelaySpec.receive(handled).should be_nil

      response.status_code.should eq(403)
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(0_i64)
      metrics = api.metrics.render(api.store, api.handoffs)
      metrics.should contain(
        %(tinrelay_registrations_total{outcome="policy_changed"} 1)
      )
      metrics.should contain(
        %(tinrelay_registrations_total{outcome="closed"} 0)
      )
      metrics.should contain(
        %(tinrelay_registrations_total{outcome="cidr_denied"} 0)
      )
      metrics.should contain(
        %(tinrelay_registrations_total{outcome="accepted"} 0)
      )
    ensure
      api.try(&.close)
      FileUtils.rm_r(root) if root && Dir.exists?(root)
    end
  end

  it "returns policy closure without a retry time for a current request" do
    closed = Tinrelay::RegistrationAllowances.new(0, 0, 0, 0)
    policy = Tinrelay::TinrelaydConfig.new(
      registration: Tinrelay::TinrelaydConfig::Registration.new(
        closed.global_hour, closed.global_day,
        closed.per_source_hour, closed.per_source_day
      )
    )
    TinrelaySpec.with_server(runtime_policy: policy) do |_root, origin, api|
      headers = HTTP::Headers{
        "Content-Type"        => "application/json",
        "X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s,
      }
      response = HTTP::Client.post(
        "#{origin}/v1/join", headers,
        TinrelayRuntimePolicySpec.claim_body("closed-current")
      )

      response.status_code.should eq(403)
      response.body.should eq(
        %({"error":"registration_forbidden",) +
        %("message":"registration is not available from this source"})
      )
      response.headers["Retry-After"]?.should be_nil
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(0_i64)
      api.database.db.scalar("SELECT COUNT(*) FROM registration_events").should eq(0_i64)
      metrics = api.metrics.render(api.store, api.handoffs)
      metrics.should contain(
        %(tinrelay_registrations_total{outcome="closed"} 1)
      )
      metrics.should contain(
        %(tinrelay_registrations_total{outcome="cidr_denied"} 0)
      )
    end
  end

  it "publishes only canonical unique exclusions as immutable snapshots" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "tinrelayd.json")
    TinrelayRuntimePolicySpec.write_defaults(path)
    api = Tinrelay::API.new(TinrelayRuntimePolicySpec.server_config(root, path))
    begin
      TinrelayRuntimePolicySpec.claim(api, "alpha")
      TinrelayRuntimePolicySpec.write_complete(path, ["alpha"])
      api.reload_configuration
      included = api.runtime_snapshot
      included.rate_limit_excluded?("alpha").should be_true
      included.rate_limit_excluded?("beta").should be_false

      [["alpha", "alpha"], ["Alpha"]].each do |exclude|
        TinrelayRuntimePolicySpec.write_complete(path, exclude)
        expect_raises(Tinrelay::Invalid) { api.reload_configuration }
        api.runtime_snapshot.same?(included).should be_true
      end

      TinrelayRuntimePolicySpec.write_complete(path)
      api.reload_configuration
      api.runtime_snapshot.rate_limit_excluded?("alpha").should be_false
      included.rate_limit_excluded?("alpha").should be_true
    ensure
      api.close
      FileUtils.rm_r(root)
    end
  end

  it "resolves direct peers canonically and ignores the client header" do
    policy = Tinrelay::ClientAddressPolicy.new("direct", [] of String)
    headers = HTTP::Headers.new
    headers.add(Tinrelay::ClientAddressPolicy::HEADER, "203.0.113.1")
    headers.add(Tinrelay::ClientAddressPolicy::HEADER, "not-an-address")
    peer = Socket::IPAddress.new("::ffff:192.0.2.10", 4321)
    policy.resolve(peer, headers).address.should eq("192.0.2.10")

    expect_raises(Tinrelay::Invalid) { policy.resolve(nil, headers) }
    {% if flag?(:darwin) || flag?(:linux) %}
      unix = Socket::UNIXAddress.new("/tmp/tinrelay-policy-spec")
      expect_raises(Tinrelay::Invalid) { policy.resolve(unix, headers) }
    {% end %}
  end

  it "trusts exactly one literal client address only from a configured ingress" do
    policy = Tinrelay::ClientAddressPolicy.new(
      "trusted_proxy", ["192.0.2.0/24", "2001:db8::/32"]
    )
    headers = HTTP::Headers{
      Tinrelay::ClientAddressPolicy::HEADER => "2001:0db8:0:0::5",
    }
    mapped_peer = Socket::IPAddress.new("::ffff:192.0.2.8", 4321)
    policy.resolve(mapped_peer, headers).address.should eq("2001:db8::5")

    untrusted = Socket::IPAddress.new("198.51.100.8", 4321)
    expect_raises(Tinrelay::Invalid) { policy.resolve(untrusted, headers) }
    expect_raises(Tinrelay::Invalid) { policy.resolve(mapped_peer, HTTP::Headers.new) }

    duplicate = HTTP::Headers.new
    duplicate.add(Tinrelay::ClientAddressPolicy::HEADER, "192.0.2.9")
    duplicate.add(Tinrelay::ClientAddressPolicy::HEADER, "192.0.2.10")
    expect_raises(Tinrelay::Invalid) { policy.resolve(mapped_peer, duplicate) }

    ["192.0.2.9, 192.0.2.10", "client.example"].each do |value|
      bad = HTTP::Headers{Tinrelay::ClientAddressPolicy::HEADER => value}
      expect_raises(Tinrelay::Invalid) { policy.resolve(mapped_peer, bad) }
    end

    expect_raises(Tinrelay::Invalid) do
      Tinrelay::ClientAddressPolicy.new("trusted_proxy", [] of String)
    end
    expect_raises(Tinrelay::Invalid) do
      Tinrelay::ClientAddressPolicy.new("trusted_proxy", ["192.0.2.0/33"])
    end
  end
end
