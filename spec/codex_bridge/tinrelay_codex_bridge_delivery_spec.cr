require "../support/tinrelay_codex_bridge_process_harness"

describe "tinrelay-codex-bridge delivery contract" do
  it "can deliver exact and fallback events as self-attributed body-free pointers" do
    TinrelayCodexBridgeProcessSpec.with_harness do |h|
      events = [
        TinrelayCodexBridgeProcessSpec.event,
        TinrelayCodexBridgeProcessSpec.event(2, "hail", nil),
        TinrelayCodexBridgeProcessSpec.event(3, "rejected_transmission", nil),
      ]
      h.config["events"] = JSON.parse(events.to_json)
      h.save

      h.start(extra: ["--pointer"])
      TinrelayCodexBridgeProcessSpec.eventually { h.child_calls("wait").size == 4 }

      sends = h.codex_calls("send")
      sends.size.should eq(3)
      sends.each_with_index do |request, index|
        expected = index == 0 ? OTHER_TASK : TASK
        request["sourceTaskId"].as_s.should eq(expected)
        request["targetTaskId"].as_s.should eq(expected)
        request["prompt"].as_s.should eq(events[index][:wrapper])
      end
      h.child_calls("routed").size.should eq(3)
      File.exists?(h.pending_target_path).should be_false
    end
  end

  it "dereferences transmissions into full message deliveries by default" do
    TinrelayCodexBridgeProcessSpec.with_harness do |h|
      event = TinrelayCodexBridgeProcessSpec.event
      h.config["events"] = JSON.parse([event].to_json)
      h.add_inbox_record(event)
      h.save

      h.start
      TinrelayCodexBridgeProcessSpec.eventually { h.child_calls("wait").size == 2 }

      prompt = h.codex_calls("send").first["prompt"].as_s
      lines = prompt.lines
      lines.first.should eq("TINRELAY MESSAGE DELIVERY")
      delivery = JSON.parse(lines[1])
      delivery["contract"].as_s.should eq("tinrelay-message-delivery-v2")
      delivery.as_h.keys.sort.should eq([
        "attention_label",
        "author_label",
        "body",
        "contract",
        "kind",
        "local_ship",
        "received_at",
        "sender_ship",
        "transmission_id",
      ])
      delivery["transmission_id"].as_s.should eq(event[:source_id])
      delivery["sender_ship"].as_s.should eq("remote")
      delivery["attention_label"].as_s.should eq("operator")
      delivery["author_label"].as_s.should eq("sender")
      delivery["body"].as_s.should eq("Exact message text.\nSecond line.")
      delivery["received_at"].as_i64.should eq(1_789_605_582_i64)
      h.child_calls.count do |call|
        call["args"].as_a.first(2).map(&.as_s) == ["inbox", "show"]
      end.should eq(1)
    end
  end

  it "rejects deliveries without a positive integer receive time" do
    [
      {"missing", nil},
      {"zero", JSON::Any.new(0_i64)},
      {"string", JSON::Any.new("1789605582")},
    ].each do |label, received_at|
      TinrelayCodexBridgeProcessSpec.with_harness do |h|
        event = TinrelayCodexBridgeProcessSpec.event
        h.config["events"] = JSON.parse([event].to_json)
        h.add_inbox_record(event)
        record = h.config["inbox_records"][event[:source_id]].as_h
        if received_at
          record["received_at"] = received_at
        else
          record.delete("received_at")
        end
        h.save

        process = h.start
        h.assert_blocked(process, "invalid_inbox_output")
        h.codex_calls("send").should be_empty, label
        h.child_calls("routed").should be_empty, label
      end
    end
  end

  it "never falls through from an invalid exact address to the fallback" do
    TinrelayCodexBridgeProcessSpec.with_harness do |h|
      event = TinrelayCodexBridgeProcessSpec.event
      h.config["events"] = JSON.parse([event].to_json)
      h.save
      h.write_addresses({
        "operator" => h.address("not-a-task"),
        "*"        => h.address(TASK),
      })

      process = h.start
      h.assert_blocked(process, "invalid_address")
      h.codex_calls("send").should be_empty
      h.child_calls("routed").should be_empty
    end
  end
end
