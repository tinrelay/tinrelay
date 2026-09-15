require "./spec_helper"

describe "repeater metrics" do
  it "serves aggregate no-store metrics without protocol negotiation" do
    TinrelaySpec.with_server do |root, origin, api|
      initial = HTTP::Client.get("#{origin}/metrics")
      initial.status_code.should eq(200)
      initial.headers["Content-Type"].should eq("text/plain; version=0.0.4; charset=utf-8")
      initial.headers["Cache-Control"].should eq("no-store")
      initial.body.should contain("tinrelay_registered_ships{state=\"active\"} 0")

      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit(root, origin, "beta")
      envelope = alpha.send("crew@alpha", "queued self transmission")
      alpha.hail("beta")
      waiter = api.handoffs.park("alpha", 1)
      invalid_headers = HTTP::Headers{
        "X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s,
      }
      invalid = HTTP::Client.post(
        "#{origin}/v1/transmissions", headers: invalid_headers, body: "{"
      )
      invalid.status_code.should eq(400)

      response = HTTP::Client.get("#{origin}/metrics")
      api.handoffs.release("alpha", waiter)

      response.body.should contain("tinrelay_registered_ships{state=\"active\"} 2")
      response.body.should contain("tinrelay_relationships{state=\"active\"} 0")
      response.body.should contain("tinrelay_relationships{state=\"transitioning\"} 0")
      response.body.should contain("tinrelay_radio_waits_active 1")
      response.body.should contain("tinrelay_queued_transmissions 1")
      response.body.should contain("tinrelay_queued_hails 1")
      response.body.should contain("tinrelay_registrations_total{outcome=\"accepted\"} 2")
      response.body.should contain("tinrelay_registrations_total{outcome=\"cidr_denied\"} 0")
      response.body.should contain("tinrelay_registrations_total{outcome=\"closed\"} 0")
      response.body.should contain("tinrelay_registrations_total{outcome=\"policy_changed\"} 0")
      response.body.should contain("tinrelay_transmissions_total{outcome=\"queued\"} 1")
      response.body.should contain("tinrelay_transmissions_total{outcome=\"rejected\"} 1")
      response.body.should contain("tinrelay_hails_total{outcome=\"accepted\"} 1")
      response.body.should contain("tinrelay_radio_waits_total{outcome=\"disconnect\"} 0")
      response.body.should contain("tinrelay_retained_ciphertext_bytes ")
      sqlite_files_bytes = ["", "-wal", "-shm"].sum do |suffix|
        File.info?(File.join(root, "service.db#{suffix}")).try(&.size) || 0_i64
      end
      response.body.should contain("tinrelay_sqlite_files_bytes #{sqlite_files_bytes}")
      response.body.should contain("tinrelay_permanent_metadata_items{state=\"used\"} 6")
      response.body.should contain("tinrelay_permanent_metadata_items{state=\"limit\"} 25000")
      response.body.should contain("tinrelay_configuration_generation 1")
      response.body.should contain("tinrelay_build_info{build=\"")
      response.body.should match(
        /tinrelay_transmission_ciphertext_bytes_total\{outcome="queued"\} [1-9][0-9]*/
      )
      response.body.should_not contain("alpha")
      response.body.should_not contain("beta")

      alpha.acknowledge(envelope.transmission_id)
      api.metrics.configuration_reload("accepted")
      updated = HTTP::Client.get("#{origin}/metrics")
      updated.body.should contain("tinrelay_transmissions_total{outcome=\"acknowledged\"} 1")
      updated.body.should contain("tinrelay_acknowledgement_latency_seconds_count 1")
      updated.body.should contain("tinrelay_configuration_generation 2")

      head = HTTP::Client.head("#{origin}/metrics")
      head.status_code.should eq(200)
      head.body.should be_empty
      head.headers["Content-Length"].to_i.should eq(updated.body.bytesize)
    end
  end
end
