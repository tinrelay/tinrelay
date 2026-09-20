require "./runtime"

module Tinrelay
  @[Link("sodium")]
  lib LibSodium
    fun crypto_pwhash(
      out : UInt8*,
      out_len : UInt64,
      password : UInt8*,
      password_len : UInt64,
      salt : UInt8*,
      opslimit : UInt64,
      memlimit : LibC::SizeT,
      algorithm : Int32,
    ) : Int32
    fun crypto_pwhash_alg_argon2id13 : Int32

    fun crypto_aead_xchacha20poly1305_ietf_encrypt(
      ciphertext : UInt8*,
      ciphertext_len : UInt64*,
      message : UInt8*,
      message_len : UInt64,
      additional : UInt8*,
      additional_len : UInt64,
      nsec : UInt8*,
      nonce : UInt8*,
      key : UInt8*,
    ) : Int32
    fun crypto_aead_xchacha20poly1305_ietf_decrypt(
      message : UInt8*,
      message_len : UInt64*,
      nsec : UInt8*,
      ciphertext : UInt8*,
      ciphertext_len : UInt64,
      additional : UInt8*,
      additional_len : UInt64,
      nonce : UInt8*,
      key : UInt8*,
    ) : Int32
  end

  # Protocol 1 originally wrapped local keys with a passphrase that the ordinary
  # unattended setup stored beside them. This file is loaded only by `tinrelay
  # migrate` and its tests so no ordinary client API understands that format.
  private class LegacyEncryptedKeyFile
    include JSON::Serializable

    property format : Int32
    property kdf : String
    property salt : String
    property nonce : String
    property ciphertext : String
  end

  private module LegacyKeyFileCrypto
    SALT_BYTES       = 16
    KEY_BYTES        = 32
    NONCE_BYTES      = 24
    TAG_BYTES        = 16
    KDF_PROFILE      = "argon2id13-opslimit3-mem64m"
    KEYRING_DOMAIN   = "tinrelay-keyring-v1".to_slice
    OWNER_KEY_DOMAIN = "tinrelay-owner-key-v1".to_slice

    def self.decrypt_keyring(ciphertext : Bytes, salt : Bytes, nonce : Bytes,
                             passphrase : String) : Bytes
      decrypt(ciphertext, salt, nonce, passphrase, KEYRING_DOMAIN)
    end

    def self.decrypt_owner_key(ciphertext : Bytes, salt : Bytes, nonce : Bytes,
                               passphrase : String) : Bytes
      decrypt(ciphertext, salt, nonce, passphrase, OWNER_KEY_DOMAIN)
    end

    private def self.decrypt(ciphertext : Bytes, salt : Bytes, nonce : Bytes,
                             passphrase : String, domain : Bytes) : Bytes
      raise Invalid.new("invalid keyring salt length") unless salt.size == SALT_BYTES
      raise Invalid.new("invalid keyring nonce length") unless nonce.size == NONCE_BYTES
      raise Invalid.new("encrypted keyring is too short") if ciphertext.size < TAG_BYTES
      key = derive_key(passphrase, salt)
      begin
        plaintext = Bytes.new(ciphertext.size - TAG_BYTES)
        plaintext_len = 0_u64
        result = LibSodium.crypto_aead_xchacha20poly1305_ietf_decrypt(
          plaintext, pointerof(plaintext_len), Pointer(UInt8).null,
          ciphertext, ciphertext.size.to_u64, domain, domain.size.to_u64,
          nonce, key
        )
        raise Unauthorized.new("keyring passphrase or contents are invalid") unless result == 0
        plaintext[0, plaintext_len.to_i]
      ensure
        Crypto.memzero(key)
      end
    end

    private def self.derive_key(passphrase : String, salt : Bytes) : Bytes
      Crypto.init
      key = Bytes.new(KEY_BYTES)
      password = passphrase.to_slice
      result = LibSodium.crypto_pwhash(
        key, key.size.to_u64, password, password.size.to_u64, salt,
        3_u64, (64 * 1024 * 1024).to_u64, LibSodium.crypto_pwhash_alg_argon2id13
      )
      unless result == 0
        Crypto.memzero(key)
        raise Error.new("key derivation failed")
      end
      key
    end
  end

  class Keyring
    # Convert the obsolete passphrase-wrapped files to ordinary owner-only JSON.
    # Either file may already be converted after an interrupted attempt.
    def self.migration_required?(path : String, owner_path : String? = nil) : Bool
      owner_file = owner_path || "#{path}.owner"
      synchronize_path(path) do
        legacy_file?(read_private(path, "keyring")) ||
          legacy_file?(read_private(owner_file, "owner key"))
      end
    end

    def self.migrate(path : String, passphrase : String?,
                     owner_path : String? = nil) : Bool
      owner_file = owner_path || "#{path}.owner"
      synchronize_path(path) do
        keyring_encoded = read_private(path, "keyring")
        owner_encoded = read_private(owner_file, "owner key")
        legacy_keyring = legacy_file?(keyring_encoded)
        legacy_owner = legacy_file?(owner_encoded)
        phrase = passphrase
        if (legacy_keyring || legacy_owner) && phrase.nil?
          raise Invalid.new("legacy key migration requires a passphrase")
        end
        data = if legacy_keyring
                 decrypt_legacy_keyring(keyring_encoded, phrase.not_nil!)
               else
                 load_plain_keyring(keyring_encoded)
               end
        owner = if legacy_owner
                  decrypt_legacy_owner(owner_encoded, phrase.not_nil!)
                else
                  load_plain_owner(owner_encoded)
                end
        validate_owner!(data, owner)
        return false unless legacy_keyring || legacy_owner

        AtomicPrivateFile.write(owner_file, owner.to_pretty_json + '\n') if legacy_owner
        AtomicPrivateFile.write(path, data.to_pretty_json + '\n') if legacy_keyring
        true
      end
    end

    private def self.decrypt_legacy_keyring(encoded : String,
                                            passphrase : String) : KeyringData
      envelope = LegacyEncryptedKeyFile.from_json(encoded)
      validate_legacy_envelope!(envelope, "keyring")
      plaintext = LegacyKeyFileCrypto.decrypt_keyring(
        Crypto.unb64(envelope.ciphertext, "keyring ciphertext"),
        Crypto.unb64(envelope.salt, "keyring salt"),
        Crypto.unb64(envelope.nonce, "keyring nonce"), passphrase
      )
      load_plain_keyring(String.new(plaintext))
    end

    private def self.decrypt_legacy_owner(encoded : String,
                                          passphrase : String) : OwnerKeyData
      envelope = LegacyEncryptedKeyFile.from_json(encoded)
      validate_legacy_envelope!(envelope, "owner key")
      plaintext = LegacyKeyFileCrypto.decrypt_owner_key(
        Crypto.unb64(envelope.ciphertext, "owner key ciphertext"),
        Crypto.unb64(envelope.salt, "owner key salt"),
        Crypto.unb64(envelope.nonce, "owner key nonce"), passphrase
      )
      load_plain_owner(String.new(plaintext))
    end

    private def self.validate_legacy_envelope!(envelope : LegacyEncryptedKeyFile,
                                               label : String) : Nil
      raise Invalid.new("unsupported #{label} envelope format") unless envelope.format == 1
      unless envelope.kdf == LegacyKeyFileCrypto::KDF_PROFILE
        raise Invalid.new("unsupported #{label} KDF profile")
      end
    end
  end
end
