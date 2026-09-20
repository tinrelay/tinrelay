require "json"
require "socket"
require "http/headers"

module Tinrelay
  struct RegistrationAllowances
    DEFAULT_GLOBAL_HOUR     =  300
    DEFAULT_GLOBAL_DAY      = 1000
    DEFAULT_PER_SOURCE_HOUR =    4
    DEFAULT_PER_SOURCE_DAY  =    4

    getter global_hour : Int32
    getter global_day : Int32
    getter per_source_hour : Int32
    getter per_source_day : Int32

    def initialize(@global_hour = DEFAULT_GLOBAL_HOUR,
                   @global_day = DEFAULT_GLOBAL_DAY,
                   @per_source_hour = DEFAULT_PER_SOURCE_HOUR,
                   @per_source_day = DEFAULT_PER_SOURCE_DAY)
      unless {global_hour, global_day, per_source_hour, per_source_day}.all?(&.>= 0)
        raise Invalid.new("registration allowances must be non-negative")
      end
    end

    def closed? : Bool
      {global_hour, global_day, per_source_hour, per_source_day}.any?(&.zero?)
    end
  end

  module LiteralIP
    def self.parse(value : String) : Socket::IPAddress
      raise Invalid.new("client address is invalid") if value.includes?('%')
      address = Socket::IPAddress.new(value, 0)
      normalized = address.address
      if normalized.starts_with?("::ffff:")
        Socket::IPAddress.new(normalized.byte_slice(7), 0)
      else
        Socket::IPAddress.new(normalized, 0)
      end
    rescue Socket::Error
      raise Invalid.new("client address is invalid")
    end

    def self.peer(value : Socket::Address?) : Socket::IPAddress
      address = value.as?(Socket::IPAddress) ||
                raise Invalid.new("client address cannot be resolved")
      parse(address.address)
    end

    def self.number(address : Socket::IPAddress) : {Int32, UInt128}
      if fields = Socket::IPAddress.parse_v4_fields?(address.address)
        value = fields.reduce(0_u128) { |number, field| (number << 8) | field }
        {32, value}
      elsif fields = Socket::IPAddress.parse_v6_fields?(address.address)
        value = fields.reduce(0_u128) { |number, field| (number << 16) | field }
        {128, value}
      else
        raise Invalid.new("client address is invalid")
      end
    end

    def self.source_bucket(address : Socket::IPAddress) : String
      bits, number = number(address)
      return "#{address.address}/32" if bits == 32

      fields = Array(String).new(8) do |index|
        value = index < 4 ? (number >> ((7 - index) * 16)) & 0xffff_u128 : 0_u128
        value.to_s(16)
      end
      network = Socket::IPAddress.new(fields.join(':'), 0)
      "#{network.address}/64"
    end
  end

  struct IPNetwork
    @bits : Int32
    @network : UInt128
    @mask : UInt128

    def initialize(source : String)
      parts = source.split('/')
      raise Invalid.new("client address CIDR is invalid") unless parts.size == 2
      address = LiteralIP.parse(parts[0])
      @bits, number = LiteralIP.number(address)
      prefix = parts[1].to_i?
      unless prefix && prefix.in?(0..@bits)
        raise Invalid.new("client address CIDR is invalid")
      end
      full_mask = @bits == 128 ? UInt128::MAX : (1_u128 << @bits) - 1
      remaining = @bits - prefix
      @mask = prefix.zero? ? 0_u128 : (full_mask >> remaining) << remaining
      @network = number & @mask
    end

    def includes?(address : Socket::IPAddress) : Bool
      bits, number = LiteralIP.number(address)
      bits == @bits && number & @mask == @network
    end
  end

  enum ClientAddressMode
    Direct
    TrustedProxy
  end

  class ClientAddressPolicy
    HEADER = "X-Tinrelay-Client-IP"

    getter mode : ClientAddressMode
    @trusted_ingress_cidrs : Array(IPNetwork)

    def initialize(mode : String, trusted_ingress_cidrs : Array(String))
      @mode = case mode
              when "direct"        then ClientAddressMode::Direct
              when "trusted_proxy" then ClientAddressMode::TrustedProxy
              else
                raise Invalid.new("client address mode is invalid")
              end
      @trusted_ingress_cidrs = trusted_ingress_cidrs.map { |cidr| IPNetwork.new(cidr) }
      if @mode.trusted_proxy? && @trusted_ingress_cidrs.empty?
        raise Invalid.new("trusted proxy mode requires a trusted ingress CIDR")
      end
    end

    def trusted_ingress_cidrs : Array(IPNetwork)
      @trusted_ingress_cidrs.dup
    end

    def resolve(peer : Socket::Address?,
                headers : HTTP::Headers) : Socket::IPAddress
      socket_address = LiteralIP.peer(peer)
      return socket_address if mode.direct?
      unless @trusted_ingress_cidrs.any?(&.includes?(socket_address))
        raise Invalid.new("client address cannot be resolved")
      end
      values = headers.get?(HEADER)
      unless values && values.size == 1 && !values[0].includes?(',')
        raise Invalid.new("client address cannot be resolved")
      end
      LiteralIP.parse(values[0])
    end
  end

  class TinrelaydConfig
    MAX_BYTES          = 64 * 1024
    MAX_EXCLUDED_SHIPS = 256
    DEFAULT_PATH       = "tinrelayd.json"

    class Registration
      include JSON::Serializable
      include JSON::Serializable::Strict

      getter global_hour : Int32 = RegistrationAllowances::DEFAULT_GLOBAL_HOUR
      getter global_day : Int32 = RegistrationAllowances::DEFAULT_GLOBAL_DAY
      getter per_source_hour : Int32 = RegistrationAllowances::DEFAULT_PER_SOURCE_HOUR
      getter per_source_day : Int32 = RegistrationAllowances::DEFAULT_PER_SOURCE_DAY
      getter deny_cidrs : Array(String) = [] of String
      getter exclude : Array(String) = [] of String

      def initialize(@global_hour = RegistrationAllowances::DEFAULT_GLOBAL_HOUR,
                     @global_day = RegistrationAllowances::DEFAULT_GLOBAL_DAY,
                     @per_source_hour = RegistrationAllowances::DEFAULT_PER_SOURCE_HOUR,
                     @per_source_day = RegistrationAllowances::DEFAULT_PER_SOURCE_DAY,
                     @deny_cidrs = [] of String,
                     @exclude = [] of String)
      end
    end

    class ClientAddress
      include JSON::Serializable
      include JSON::Serializable::Strict

      getter mode : String = "direct"
      getter trusted_ingress_cidrs : Array(String) = [] of String

      def initialize(@mode = "direct", @trusted_ingress_cidrs = [] of String)
      end
    end

    class Logging
      include JSON::Serializable
      include JSON::Serializable::Strict

      getter requests : Bool = true

      def initialize(@requests = true)
      end
    end

    include JSON::Serializable
    include JSON::Serializable::Strict

    getter registration : Registration = Registration.new
    getter client_address : ClientAddress = ClientAddress.new
    getter logging : Logging = Logging.new

    def initialize(@registration = Registration.new,
                   @client_address = ClientAddress.new,
                   @logging = Logging.new)
    end

    def registration_allowances : RegistrationAllowances
      RegistrationAllowances.new(
        registration.global_hour, registration.global_day,
        registration.per_source_hour, registration.per_source_day
      )
    end

    def registration_deny_cidrs : Array(IPNetwork)
      registration.deny_cidrs.map { |cidr| IPNetwork.new(cidr) }
    end

    def rate_limit_exclusions : Array(String)
      ships = registration.exclude
      if ships.size > MAX_EXCLUDED_SHIPS
        raise Invalid.new("too many rate-limit exclusions")
      end
      seen = {} of String => Bool
      ships.each do |ship|
        Names.ship!(ship)
        raise Invalid.new("rate-limit exclusions must be unique") if seen.has_key?(ship)
        seen[ship] = true
      end
      ships.dup
    end

    def client_address_policy : ClientAddressPolicy
      ClientAddressPolicy.new(
        client_address.mode, client_address.trusted_ingress_cidrs
      )
    end

    def self.load(explicit_path : String?, allow_missing_default = true) : self?
      path = explicit_path || DEFAULT_PATH
      bytes = File.open(path) do |file|
        buffer = IO::Memory.new
        count = IO.copy(file, buffer, MAX_BYTES + 1)
        if count > MAX_BYTES
          raise Invalid.new("tinrelayd configuration exceeds #{MAX_BYTES} bytes")
        end
        buffer.to_s
      end
      from_json(bytes)
    rescue File::NotFoundError
      return nil if explicit_path.nil? && allow_missing_default
      raise Invalid.new("tinrelayd configuration cannot be read")
    rescue ex : File::Error
      raise Invalid.new("tinrelayd configuration cannot be read")
    rescue ex : JSON::ParseException | JSON::SerializableError
      raise Invalid.new("tinrelayd configuration is invalid")
    end
  end
end
