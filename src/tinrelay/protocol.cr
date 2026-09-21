require "json"
require "base64"
require "digest/sha256"
require "uri"

require "./version"
require "./error"
require "./crypto"
require "./model"

module Tinrelay
  MAX_ORDINARY_RESPONSE_BYTES      = 72_i64 * 1024
  DEFAULT_PERMANENT_METADATA_LIMIT =  25_000_i64
  MAX_PERMANENT_METADATA_LIMIT     = 100_000_i64
  MAX_IDENTITY_RESPONSE_BYTES      = 64_i64 * 1024 * 1024
  RADIO_WAIT_HOLD_SECONDS          = 100

  module Ids
    def self.uuid : String
      bytes = Crypto.random(16)
      bytes[6] = (bytes[6] & 0x0f) | 0x40
      bytes[8] = (bytes[8] & 0x3f) | 0x80
      hex = bytes.hexstring
      "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
    end
  end

  module RejectionEvidence
    ID = /\Atr_[0-9a-f]{32}\z/

    def self.id(transmission_id : String, reason : String) : String
      digest = Digest::SHA256.hexdigest(
        Canonical.fields(
          "tinrelay-local-evidence-v1", "rejection", "#{transmission_id}:#{reason}"
        )
      )
      "tr_#{digest[0, 32]}"
    end
  end

  module Origin
    def self.validate!(origin : String) : Nil
      uri = URI.parse(origin)
      local = uri.host.in?({"127.0.0.1", "localhost", "::1"})
      unless uri.scheme == "https" || (uri.scheme == "http" && local)
        raise Invalid.new("server URL must use https outside localhost")
      end
      unless uri.path.empty? || uri.path == "/"
        raise Invalid.new("server URL must not include a path")
      end
      if uri.user || uri.password || uri.query || uri.fragment
        raise Invalid.new("server URL must not contain credentials, query, or fragment")
      end
    end
  end
end
