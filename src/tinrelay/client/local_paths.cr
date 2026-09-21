module Tinrelay
  struct LocalPaths
    getter keyring : String
    getter owner_key : String
    getter spool : String
    getter outbox : String
    getter outgoing : String
    getter outgoing_observer : String

    def initialize(ship : String, home : String)
      ship = Names.ship!(ship)
      config = File.join(home, ".config", "tinrelay", ship)
      @keyring = File.join(config, "keyring")
      @owner_key = File.join(config, "owner-key")
      @outgoing_observer = File.join(config, "outgoing-observer.json")
      @spool = File.join(home, ".local", "share", "tinrelay", ship, "inbox")
      @outbox = File.join(home, ".local", "share", "tinrelay", ship, "outbox")
      @outgoing = File.join(home, ".local", "share", "tinrelay", ship, "outgoing")
    end
  end
end
