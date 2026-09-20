require "../support/tinrelay_codex_bridge_process_harness"

describe "tinrelay-codex-bridge command contract" do
  it "rejects an invalid timeout" do
    TinrelayCodexBridgeProcessSpec.with_harness do |h|
      process = h.start(extra: ["--timeout", "never"])

      h.assert_blocked(process, "invalid_timeout")
    end
  end

  it "installs the platform bridge through one top-level command" do
    TinrelayCodexBridgeProcessSpec.with_harness do |h|
      process = h.start_install

      process.wait(10.seconds).exit_code.should eq(0)
      {% if flag?(:darwin) %}
        h.output.should eq("codex_restart_required\n")
        relay = File.join(h.root, "codex", "codex-bridge", "relay.mjs")
        File.read(relay).should contain("send_message_to_thread")
      {% else %}
        h.output.should eq("ready\n")
      {% end %}
    end
  end

  it "checks discovery and the address book without sending a message" do
    TinrelayCodexBridgeProcessSpec.with_harness do |h|
      process = h.start("check")

      process.wait.exit_code.should eq(0)
      h.output.should contain(%("state":"ready"))
      h.codex_calls("discover").size.should eq(1)
      h.codex_calls("send").should be_empty
    end
  end

  it "accepts the now-redundant deref option from existing service definitions" do
    TinrelayCodexBridgeProcessSpec.with_harness do |h|
      process = h.start("check", extra: ["--deref"])

      process.wait.exit_code.should eq(0)
      h.output.should contain(%("state":"ready"))
    end
  end
end
