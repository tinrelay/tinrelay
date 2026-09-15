module TinrelaySpec::LegacyKeyFiles
  SALT_BYTES       = 16
  KEY_BYTES        = 32
  NONCE_BYTES      = 24
  TAG_BYTES        = 16
  KDF_PROFILE      = "argon2id13-opslimit3-mem64m"
  KEYRING_DOMAIN   = "tinrelay-keyring-v1".to_slice
  OWNER_KEY_DOMAIN = "tinrelay-owner-key-v1".to_slice

  def self.wrap(keyring : Tinrelay::Keyring, passphrase : String) : Nil
    wrap_file(keyring.path, passphrase, KEYRING_DOMAIN)
    wrap_file(keyring.owner_path, passphrase, OWNER_KEY_DOMAIN)
  end

  def self.wrap_file(path : String, passphrase : String, additional : Bytes) : Nil
    plaintext = File.read(path).to_slice
    salt = Tinrelay::Crypto.random(SALT_BYTES)
    nonce = Tinrelay::Crypto.random(NONCE_BYTES)
    key = derive_key(passphrase, salt)
    begin
      ciphertext = Bytes.new(plaintext.size + TAG_BYTES)
      ciphertext_len = 0_u64
      result = Tinrelay::LibSodium.crypto_aead_xchacha20poly1305_ietf_encrypt(
        ciphertext, pointerof(ciphertext_len), plaintext, plaintext.size.to_u64,
        additional, additional.size.to_u64, Pointer(UInt8).null, nonce, key
      )
      raise "could not construct legacy key fixture" unless result == 0
      encoded = {
        format:     1,
        kdf:        KDF_PROFILE,
        salt:       Tinrelay::Crypto.b64(salt),
        nonce:      Tinrelay::Crypto.b64(nonce),
        ciphertext: Tinrelay::Crypto.b64(ciphertext[0, ciphertext_len.to_i]),
      }.to_pretty_json
      Tinrelay::AtomicPrivateFile.write(path, encoded + '\n')
    ensure
      Tinrelay::Crypto.memzero(key)
    end
  end

  private def self.derive_key(passphrase : String, salt : Bytes) : Bytes
    key = Bytes.new(KEY_BYTES)
    password = passphrase.to_slice
    result = Tinrelay::LibSodium.crypto_pwhash(
      key, key.size.to_u64, password, password.size.to_u64, salt,
      3_u64, (64 * 1024 * 1024).to_u64,
      Tinrelay::LibSodium.crypto_pwhash_alg_argon2id13
    )
    raise "could not construct legacy key fixture" unless result == 0
    key
  end
end
