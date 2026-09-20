require "../spec_helper"

describe "the API protocol boundary" do
  it "rejects older and newer clients and accepts the exact protocol" do
    TinrelaySpec.with_server do |_root, origin, _api|
      older = HTTP::Client.post(
        "#{origin}/v1/ships/inspect",
        HTTP::Headers{"X-Tinrelay-Protocol" => (Tinrelay::PROTOCOL - 1).to_s}
      )
      older.status_code.should eq(426)
      older_body = JSON.parse(older.body)
      older_body.as_h.keys.sort.should eq(%w(
        client_protocol error relation supported_max supported_min
      ))
      older_body["error"].as_s.should eq("protocol_incompatible")
      older_body["client_protocol"].as_i.should eq(Tinrelay::PROTOCOL - 1)
      older_body["supported_min"].as_i.should eq(Tinrelay::PROTOCOL)
      older_body["supported_max"].as_i.should eq(Tinrelay::PROTOCOL)
      older_body["relation"].as_s.should eq("older")

      newer = HTTP::Client.post(
        "#{origin}/v1/ships/inspect",
        HTTP::Headers{"X-Tinrelay-Protocol" => (Tinrelay::PROTOCOL + 1).to_s}
      )
      newer.status_code.should eq(426)
      JSON.parse(newer.body)["relation"].as_s.should eq("newer")

      exact = HTTP::Client.post(
        "#{origin}/v1/ships/inspect",
        HTTP::Headers{"X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s}
      )
      exact.status_code.should eq(400)

      absent = HTTP::Client.post("#{origin}/v1/ships/inspect")
      absent.status_code.should eq(426)
      JSON.parse(absent.body)["relation"].as_s.should eq("older")
    end
  end
end
