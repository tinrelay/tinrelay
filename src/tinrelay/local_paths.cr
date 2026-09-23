require "./names"

module Tinrelay
  struct LocalPaths
    getter config_directory : String
    getter keyring : String
    getter owner_key : String
    getter spool : String
    getter outbox : String
    getter outgoing : String
    getter outgoing_observer : String

    def initialize(ship : String, @home : String)
      @ship = Names.ship!(ship)
      @config_directory = File.join(home, ".config", "tinrelay", ship)
      @keyring = File.join(config_directory, "keyring")
      @owner_key = File.join(config_directory, "owner-key")
      @outgoing_observer = File.join(config_directory, "outgoing-observer.json")
      data = File.join(home, ".local", "share", "tinrelay", ship)
      @spool = File.join(data, "inbox")
      @outbox = File.join(data, "outbox")
      @outgoing = File.join(data, "outgoing")
    end

    def codex_addresses : String
      File.join(config_directory, "codex-addresses.json")
    end

    def local_delivery_lock : String
      File.join(spool, "local-delivery.lock")
    end

    def pending_target : String
      File.join(@home, ".local", "share", "tinrelay-codex-bridge", "pending", "#{@ship}.json")
    end
  end
end
