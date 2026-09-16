require "socket"

require "./spec_helper"

{% skip_file unless flag?(:darwin) || flag?(:linux) %}

module TinrelaydReloadProcessSpec
  BUILD_ROOT = File.join(Dir.tempdir, "tinrelayd-reload-spec-#{Process.pid}")
  BINARY     = File.join(BUILD_ROOT, "tinrelayd")
  SOURCE     = File.expand_path("../src/tinrelayd_cli.cr", __DIR__)
  @@binary_ready = false

  def self.ensure_binary : Nil
    return if @@binary_ready && File.file?(BINARY)
    Dir.mkdir_p(BUILD_ROOT)
    status = Process.run(
      "crystal",
      ["build", SOURCE, "-o", BINARY, "--release",
       "--warnings=all", "--error-on-warnings"],
      output: STDOUT,
      error: STDERR
    )
    raise "could not build current tinrelayd process fixture" unless status.success?
    @@binary_ready = true
  end

  def self.available_port : Int32
    socket = TCPServer.new("127.0.0.1", 0)
    socket.local_address.as(Socket::IPAddress).port
  ensure
    socket.try(&.close)
  end

  def self.write_config(path : String, site_name : String,
                        base_url : String, wordmark : String,
                        trusted_ingress = [] of String,
                        client_address_mode : String? = nil) : Nil
    temporary = "#{path}.next"
    File.write(temporary, {
      site: {
        site_name:         site_name,
        base_url:          base_url,
        wordmark:          wordmark,
        art_manifest_path: nil,
      },
      registration: {
        global_hour: 301, global_day: 1001,
        per_source_hour: 5, per_source_day: 6,
        deny_cidrs: ["192.0.2.0/24"],
      },
      client_address: {
        mode: client_address_mode ||
              (trusted_ingress.empty? ? "direct" : "trusted_proxy"),
        trusted_ingress_cidrs: trusted_ingress,
      },
      logging: {requests: false},
    }.to_json)
    File.rename(temporary, path)
  end

  def self.eventually(within = 5.seconds, &) : Nil
    deadline = Time.instant + within
    until yield
      raise "condition did not become true" if Time.instant >= deadline
      sleep 20.milliseconds
    end
  end

  def self.get(url : String) : HTTP::Client::Response?
    HTTP::Client.get(url)
  rescue IO::Error
    nil
  end
end

Spec.after_suite do
  root = TinrelaydReloadProcessSpec::BUILD_ROOT
  FileUtils.rm_r(root) if Dir.exists?(root)
end

describe "tinrelayd runtime configuration process" do
  it "reloads one complete site snapshot through SIGHUP" do
    TinrelaydReloadProcessSpec.ensure_binary
    root = TinrelaySpec.temporary_root
    port = TinrelaydReloadProcessSpec.available_port
    origin = "http://127.0.0.1:#{port}"
    config_path = File.join(root, "tinrelayd.json")
    errors_path = File.join(root, "stderr.log")
    output = File.open(File.join(root, "stdout.log"), "w")
    errors = File.open(errors_path, "w")
    TinrelaydReloadProcessSpec.write_config(
      config_path, "First Site", origin, "First  Mark"
    )
    process = Process.new(
      TinrelaydReloadProcessSpec::BINARY,
      ["serve", "--database", File.join(root, "service.db"),
       "--bind", "127.0.0.1", "--port", port.to_s, "--threads", "1",
       "--bootstrap-template", File.expand_path("../templates/common-bootstrap.md", __DIR__),
       "--source-repository", "https://example.test/tinrelay.git",
       "-c", config_path],
      output: output,
      error: errors
    )
    output.close
    errors.close

    begin
      TinrelaydReloadProcessSpec.eventually do
        response = TinrelaydReloadProcessSpec.get(origin)
        response && response.body.includes?("First Site - First Site")
      end

      TinrelaydReloadProcessSpec.write_config(
        config_path, "Second Site", "http://localhost:#{port}", "Second  Mark",
        ["127.0.0.0/8"]
      )
      process.signal(Signal::HUP)
      TinrelaydReloadProcessSpec.eventually do
        response = TinrelaydReloadProcessSpec.get(origin)
        response && response.body.includes?("Second Site - Second Site") &&
          response.body.includes?("http://localhost:#{port}/") &&
          response.body.includes?("<span>Second  Mark</span>")
      end

      TinrelaydReloadProcessSpec.write_config(
        config_path, "Broken Site", "https://broken.example", "Broken Mark",
        client_address_mode: "trusted_proxy"
      )
      process.signal(Signal::HUP)
      TinrelaydReloadProcessSpec.eventually do
        File.read(errors_path).includes?(
          %("event":"configuration_reload_failed")
        ) && File.read(errors_path).includes?(
          %("message":"trusted proxy mode requires a trusted ingress CIDR")
        )
      end
      response = HTTP::Client.get(origin)
      response.body.should contain("Second Site - Second Site")
      response.body.should contain("http://localhost:#{port}/")
      response.body.should contain("<span>Second  Mark</span>")

      failures = File.read(errors_path).scan(/configuration_reload_failed/).size
      File.delete(config_path)
      process.signal(Signal::HUP)
      TinrelaydReloadProcessSpec.eventually do
        File.read(errors_path).scan(/configuration_reload_failed/).size > failures
      end
      response = HTTP::Client.get(origin)
      response.body.should contain("Second Site - Second Site")
      response.body.should contain("http://localhost:#{port}/")
      response.body.should contain("<span>Second  Mark</span>")
      HTTP::Client.get("#{origin}/readyz").status_code.should eq(200)
      log = File.read(errors_path)
      log.should contain(%("event":"configuration_reload_failed"))
      log.should_not contain(%("event":"request"))
    ensure
      process.signal(Signal::TERM)
      process.wait
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end
end
