require "../spec_helper"

class CountingInspectionRemote < Tinrelay::Remote
  getter inspections = 0

  def post(path : String, body : String) : String
    @inspections += 1 if path == "/v1/ships/inspect"
    super
  end
end

describe Tinrelay::Client do
  it "inspects once per real administrative signing step" do
    TinrelaySpec.with_server do |root, origin, _api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      remote = CountingInspectionRemote.new(origin)
      client = Tinrelay::Client.new(alpha.keyring, remote)

      client.rotate_owner.should eq(2)
      remote.inspections.should eq(2)

      client.ship_change("freeze")
      remote.inspections.should eq(4)
    end
  end

  it "signs contact close once after the final request payload is built" do
    TinrelaySpec.with_server do |root, origin, _api|
      alpha = TinrelaySpec.admit(root, origin, "alpha")
      beta = TinrelaySpec.admit(root, origin, "beta")
      TinrelaySpec.connect(root, alpha, beta)
      remote = CountingInspectionRemote.new(origin)
      client = Tinrelay::Client.new(alpha.keyring, remote)

      client.close_contact("beta").should eq(2)
      # Pending gen-2 is refused before the signed request falls back to gen-1.
      remote.inspections.should eq(3)
    end
  end
end
