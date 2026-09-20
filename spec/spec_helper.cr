require "spec"
require "file_utils"
require "../src/tinrelay/client/runtime"
require "../src/tinrelay/server/server"
{% if flag?(:win32) %}
  require "./support/windows_acl"
{% end %}

module TinrelaySpec
  DEFAULT_METADATA_LIMIT       = Tinrelay::DEFAULT_PERMANENT_METADATA_LIMIT
  OPEN_REGISTRATION_ALLOWANCES = Tinrelay::RegistrationAllowances.new(
    1_000_000, 1_000_000, 1_000_000, 1_000_000
  )
  TEST_SOURCE_BUCKET = "127.0.0.1/32"

  def self.temporary_root : String
    root = File.join(Dir.tempdir, "tinrelay-spec-#{Process.pid}-#{Tinrelay::Ids.uuid}")
    Dir.mkdir_p(root)
    root
  end

  def self.assert_private_storage(path : String, posix_mode : Int32) : Nil
    {% if flag?(:win32) %}
      Tinrelay::PrivateStorage.private?(path).should be_true
    {% elsif flag?(:darwin) || flag?(:linux) %}
      (File.info(path).permissions.value & 0o777).should eq(posix_mode)
    {% else %}
      {% raise "TinRelay specs do not support this platform" %}
    {% end %}
  end

  def self.with_server(permanent_metadata_limit : Int64 = DEFAULT_METADATA_LIMIT,
                       registration_allowances : Tinrelay::RegistrationAllowances? = nil,
                       client_address : Tinrelay::TinrelaydConfig::ClientAddress? = nil,
                       radio_wait_heartbeat_interval : Time::Span? = nil, &)
    root = temporary_root
    configuration_path = nil
    if registration_allowances || client_address
      configuration_path = File.join(root, "tinrelayd.json")
      registration = registration_allowances.try do |allowances|
        Tinrelay::TinrelaydConfig::Registration.new(
          allowances.global_hour, allowances.global_day,
          allowances.per_source_hour, allowances.per_source_day
        )
      end || Tinrelay::TinrelaydConfig::Registration.new
      File.write(
        configuration_path,
        Tinrelay::TinrelaydConfig.new(
          registration,
          client_address || Tinrelay::TinrelaydConfig::ClientAddress.new
        ).to_json
      )
    end
    config = Tinrelay::ServerConfig.new(
      "127.0.0.1", 0, File.join(root, "service.db"), System.cpu_count,
      permanent_metadata_limit, configuration_path
    )
    api = Tinrelay::API.new(
      config,
      radio_wait_heartbeat_interval || Tinrelay::API::RADIO_WAIT_HEARTBEAT_INTERVAL
    )
    server = HTTP::Server.new(api.handler)
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    origin = "http://127.0.0.1:#{address.port}"
    begin
      yield root, origin, api
    ensure
      server.close
      api.close
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  def self.radio_auth(client : Tinrelay::Client, action : String,
                      payload : Bytes, now : Int64 = Time.utc.to_unix) : Tinrelay::RadioAuth
    radio = client.keyring.data.radio!
    auth = Tinrelay::RadioAuth.new(
      client.keyring.data.ship, radio.generation, now
    )
    auth.signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        auth.signing_bytes(action, payload),
        Tinrelay::Crypto.unb64(radio.signing.secret_key)
      )
    )
    auth
  end

  def self.receive(channel : Channel(T), within = 3.seconds) : T forall T
    select
    when value = channel.receive
      value
    when timeout(within)
      raise "timed out waiting for a test channel"
    end
  end

  def self.eventually(within = 3.seconds, &) : Nil
    deadline = Time.instant + within
    until yield
      raise "timed out waiting for a causal test condition" if Time.instant >= deadline
      Fiber.yield
    end
  end

  def self.radio_wait_request(client : Tinrelay::Client,
                              hold_seconds : Int32) : Tinrelay::RadioWaitRequest
    known = client.keyring.data.contacts.to_h do |contact|
      {contact.ship, contact.radio_certificate.generation}
    end
    placeholder = Tinrelay::RadioAuth.new(
      client.keyring.data.ship,
      client.keyring.data.active_radio_generation,
      0_i64
    )
    request = Tinrelay::RadioWaitRequest.new(
      hold_seconds, placeholder, known_contact_generations: known
    )
    request.auth = radio_auth(client, "radio.wait", request.payload)
    request
  end

  def self.admit(root : String, origin : String, ship : String) : Tinrelay::Client
    Tinrelay::Client.join(File.join(root, "#{ship}.keyring"), origin, ship)
  end

  def self.claim_directly(store : Tinrelay::Store,
                          prepared : Tinrelay::PreparedShipClaim,
                          now : Int64 = Time.utc.to_unix) : Nil
    store.claim(
      prepared, TEST_SOURCE_BUCKET, OPEN_REGISTRATION_ALLOWANCES,
      -> { true }, now
    )
  end

  def self.admit_contact(root : String, origin : String, ship : String,
                         peer : Tinrelay::Client) : Tinrelay::Client
    client = admit(root, origin, ship)
    connect(root, peer, client)
    client
  end

  def self.connect(root : String, first : Tinrelay::Client,
                   second : Tinrelay::Client) : Nil
    first_spool = Tinrelay::Spool.new(File.join(
      root, "contact-#{Tinrelay::Ids.uuid[0, 8]}"
    ))
    second_spool = Tinrelay::Spool.new(File.join(
      root, "contact-#{Tinrelay::Ids.uuid[0, 8]}"
    ))

    first.hail(second.keyring.data.ship)
    event = second.radio_wait(second_spool, hold_seconds: 0)
    second_spool.routed(event.local_id)
    second.allow_contact(event.local_id, second_spool)

    second.hail(first.keyring.data.ship)
    return_event = first.radio_wait(first_spool, hold_seconds: 0)
    first_spool.routed(return_event.local_id)
    first.allow_contact(return_event.local_id, first_spool)
  end
end
