require "../support/tinrelay_codex_bridge_process_harness"

describe "tinrelay-codex-bridge lifecycle contract" do
  it "keeps one bridge owner and stops its waiting child when the bridge terminates" do
    TinrelayCodexBridgeProcessSpec.with_harness do |h|
      first = h.start
      TinrelayCodexBridgeProcessSpec.eventually { h.child_calls("wait").size == 1 }
      child_pid = h.child_calls("wait").first["pid"].as_i

      second = h.start
      second.wait.exit_code.should eq(0)
      h.output(1).should contain(%("reason":"bridge_already_running"))

      first.signal(Signal::TERM)
      status = first.wait(3.seconds)
      {% if flag?(:win32) %}
        status.exit_code.should eq(1)
      {% elsif flag?(:darwin) || flag?(:linux) %}
        status.exit_code.should eq(0)
      {% else %}
        {% raise "TinRelay specs do not support this platform" %}
      {% end %}
      TinrelayCodexBridgeProcessSpec.eventually { !Process.exists?(child_pid) }
    end
  end

  it "terminates and reaps a child recorded after stop" do
    TinrelayCodexBridgeProcessSpec.ensure_binaries
    control = TinrelayCodexBridge::Control.new
    control.stop
    process = Process.new(
      TinrelayCodexBridgeProcessSpec::FIXTURE,
      env: {"TINRELAY_CODEX_BRIDGE_PIPE_HOLDER" => "1"}
    )

    expect_raises(TinrelayCodexBridge::Stopped) do
      control.child = process
    end
    Process.exists?(process.pid).should be_false
  end

  {% if flag?(:win32) %}
    it "creates reusable private ACLs for both bridge ownership locks" do
      TinrelayCodexBridgeProcessSpec.with_harness do |h|
        process = h.start
        TinrelayCodexBridgeProcessSpec.eventually { h.child_calls("wait").size == 1 }

        locks = [
          File.join(
            h.root, ".local", "share", "tinrelay-codex-bridge", "locks", "fixture.lock"
          ),
          File.join(
            h.root, ".local", "share", "tinrelay", "fixture", "inbox",
            "local-delivery.lock"
          ),
        ]
        locks.each do |path|
          File.exists?(path).should be_true
          Tinrelay::PrivateStorage.private?(path).should be_true
          Tinrelay::PrivateStorage.private?(File.dirname(path)).should be_true
        end
        process.running?.should be_true
      end
    end
  {% end %}
end
