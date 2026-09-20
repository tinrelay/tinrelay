require "../support/tinrelay_codex_bridge_process_harness"

describe "tinrelay-codex-bridge recovery contract" do
  it "retries a definite refusal only against the frozen target" do
    TinrelayCodexBridgeProcessSpec.with_harness do |h|
      event = TinrelayCodexBridgeProcessSpec.event
      h.config["events"] = JSON.parse([event].to_json)
      h.config["codex_result"] = JSON::Any.new("not_received")
      h.add_inbox_record(event)
      h.save

      process = h.start
      TinrelayCodexBridgeProcessSpec.eventually { h.codex_calls("send").size >= 2 }
      h.write_addresses({"operator" => h.address(TASK), "*" => h.address(TASK)})
      TinrelayCodexBridgeProcessSpec.eventually { h.codex_calls("send").size >= 3 }

      h.codex_calls("send").each do |request|
        request["targetTaskId"].as_s.should eq(OTHER_TASK)
      end
      binding = JSON.parse(File.read(h.pending_target_path))
      binding["task_id"].as_s.should eq(OTHER_TASK)
      binding["state"].as_s.should eq("ready")
      process.running?.should be_true
    end
  end

  it "pins an unknown receipt and never resubmits it after restart" do
    TinrelayCodexBridgeProcessSpec.with_harness do |h|
      event = TinrelayCodexBridgeProcessSpec.event
      h.config["events"] = JSON.parse([event].to_json)
      h.config["codex_result"] = JSON::Any.new("receipt_unknown")
      h.add_inbox_record(event)
      h.save

      first = h.start
      h.assert_blocked(first, "delivery_receipt_unknown")
      h.codex_calls("send").size.should eq(1)
      binding = JSON.parse(File.read(h.pending_target_path))
      binding["state"].as_s.should eq("receipt_unknown")

      h.config["codex_result"] = JSON::Any.new("success")
      h.save
      second = h.start
      h.assert_blocked(second, "delivery_receipt_unknown")
      h.codex_calls("send").size.should eq(1)
      h.child_calls("routed").should be_empty
    end
  end

  it "finishes a definitely delivered event after a routed-mark restart" do
    TinrelayCodexBridgeProcessSpec.with_harness do |h|
      event = TinrelayCodexBridgeProcessSpec.event
      h.config["events"] = JSON.parse([event].to_json)
      h.config["routed_failure"] = JSON::Any.new(true)
      h.add_inbox_record(event)
      h.save

      first = h.start
      h.assert_blocked(first, "tinrelay_routed_failed")
      h.codex_calls("send").size.should eq(1)
      JSON.parse(File.read(h.pending_target_path))["state"].as_s.should eq("delivered")

      h.config["routed_failure"] = JSON::Any.new(false)
      h.save
      second = h.start
      TinrelayCodexBridgeProcessSpec.eventually { h.child_calls("wait").size == 3 }
      h.codex_calls("send").size.should eq(1)
      h.child_calls("routed").size.should eq(2)
      File.exists?(h.pending_target_path).should be_false
      second.running?.should be_true
    end
  end
end
