# Rails-specific extensions to Solana::Keypair (from the solana-studio gem).
# Adds admin keypair loading + versioned encrypt/decrypt for DB storage.
#
# OPSEC-015 — managed-wallet private keys are encrypted at rest in
# users.encrypted_web2_solana_private_key. The key material now comes from
# MANAGED_WALLET_ENCRYPTION_KEY (a dedicated env var, independent of
# RAILS_MASTER_KEY / secret_key_base) run through ActiveSupport::KeyGenerator
# for a full 256-bit AES key. Ciphertexts are version-tagged ("v2:") so the
# scheme is rotatable: `from_encrypted` still decrypts legacy untagged
# ciphertexts via the old secret_key_base derivation, and
# `bin/rails solana:reencrypt_managed_wallets` migrates them forward.
#
# Pre-OPSEC-015 the key was `secret_key_base[0, 32]` — 32 hex *characters*,
# i.e. only ~128 bits of real entropy, and impossible to rotate without
# orphaning every stored wallet key.

module Solana
  class Keypair
    ENCRYPTION_VERSION = "v2".freeze

    # --- test-only, deliberately NON-SECRET fallbacks ---------------------------
    # Both of the credentials this class needs (SOLANA_ADMIN_KEY, and the
    # RAILS_MASTER_KEY that decrypts credentials.secret_key_base) are GitHub
    # *repository* secrets. Dependabot pull requests run against the separate
    # Dependabot secret store and cannot see repository secrets by design, so
    # every dependency PR on this repo failed the same Solana unit tests
    # permanently -- no rebase or re-run could ever clear it.
    #
    # The deeper defect is that these are UNIT tests: they assemble and encrypt,
    # they never touch the network or a funded account. Needing a production
    # credential to run them is the bug; the Dependabot breakage is just how it
    # surfaced. Both constants below are fixed, published, worthless values used
    # ONLY when Rails.env.test?. Neither is ever reachable in any other
    # environment -- see .admin and .legacy_secret_key_base.
    TEST_ADMIN_SEED = Digest::SHA256.digest("turf-monster test-only admin keypair").freeze
    TEST_SECRET_KEY_BASE = "turf-monster-test-only-secret-key-base-not-a-real-secret".freeze

    # Load admin keypair from SOLANA_ADMIN_KEY env var (base58).
    #
    # OUTSIDE TEST THE ENV VAR IS MANDATORY AND ITS ABSENCE IS A HARD RAISE.
    # This is the Alex Bot signer: 1-of-3 on the vault multisig, the fee payer
    # and signer for create_contest / enter_contest / mint_entry_token. A
    # signing path that quietly substituted a throwaway key would build
    # transactions that are rejected on-chain (or, worse, anchored to an
    # address nobody controls) -- far worse than a red CI. The guard stays.
    #
    # Under Rails.env.test? ONLY, and only when the env var is absent, fall back
    # to a deterministic non-secret keypair. The tests that reach here exercise
    # transaction ASSEMBLY -- they need a syntactically valid ed25519 signer,
    # not a funded or privileged one, and none of them asserts this pubkey.
    # Rails.env is the discriminator on purpose: a marker like ENV["CI"] can be
    # set anywhere, including on a production dyno.
    def self.admin
      @admin ||= if ENV["SOLANA_ADMIN_KEY"].present?
        from_base58(ENV["SOLANA_ADMIN_KEY"])
      elsif Rails.env.test?
        from_bytes(TEST_ADMIN_SEED)
      else
        raise "SOLANA_ADMIN_KEY env var required"
      end
    end

    # Load from an encrypted string. Handles the current "v2:"-tagged scheme
    # and legacy untagged ciphertexts transparently.
    def self.from_encrypted(encrypted_string)
      version, payload = parse_encrypted(encrypted_string)
      decrypted = encryptor_for(version).decrypt_and_verify(payload)
      from_bytes(Base64.strict_decode64(decrypted))
    end

    # Encrypt for DB storage — always produces a current-version ciphertext.
    def encrypt
      self.class.encrypt_value(to_bytes)
    end

    def self.encrypt_value(bytes)
      payload = current_encryptor.encrypt_and_sign(Base64.strict_encode64(bytes))
      "#{ENCRYPTION_VERSION}:#{payload}"
    end

    # Re-encrypt a stored ciphertext to the current scheme: decrypt with
    # whatever version it currently is, return a fresh current-version
    # ciphertext. Drives `solana:reencrypt_managed_wallets`.
    def self.reencrypt(encrypted_string)
      from_encrypted(encrypted_string).encrypt
    end

    # True if a ciphertext is already at the current encryption version.
    def self.current_version?(encrypted_string)
      encrypted_string.to_s.start_with?("#{ENCRYPTION_VERSION}:")
    end

    def self.parse_encrypted(s)
      if current_version?(s)
        [ENCRYPTION_VERSION, s.delete_prefix("#{ENCRYPTION_VERSION}:")]
      else
        [:legacy, s]
      end
    end
    private_class_method :parse_encrypted

    def self.encryptor_for(version)
      case version
      when ENCRYPTION_VERSION then current_encryptor
      when :legacy            then legacy_encryptor
      else raise "unknown managed-wallet encryption version: #{version.inspect}"
      end
    end
    private_class_method :encryptor_for

    # Current scheme: 256-bit key derived from MANAGED_WALLET_ENCRYPTION_KEY
    # via KeyGenerator (PBKDF2 + domain-separation label). In production the
    # env var is mandatory — config/initializers/managed_wallet_encryption.rb
    # fails the boot if it's missing. Dev/test/CI fall back to secret_key_base
    # run through the SAME KDF: still a proper 256-bit key, just not
    # rotation-isolated (acceptable off-prod).
    def self.current_encryptor
      @current_encryptor ||= begin
        material = ENV["MANAGED_WALLET_ENCRYPTION_KEY"].presence ||
                   legacy_secret_key_base
        key = ActiveSupport::KeyGenerator.new(material).generate_key("turf-monster managed wallet v2", 32)
        ActiveSupport::MessageEncryptor.new(key)
      end
    end
    private_class_method :current_encryptor

    # Legacy scheme (pre-OPSEC-015): the first 32 CHARS of the hex
    # secret_key_base — only ~128 bits of real entropy. Kept solely so
    # pre-migration ciphertexts still decrypt. Never encrypt new data here.
    def self.legacy_encryptor
      @legacy_encryptor ||= ActiveSupport::MessageEncryptor.new(
        legacy_secret_key_base[0, 32]
      )
    end
    private_class_method :legacy_encryptor

    # The secret_key_base both encryptors key off when no dedicated
    # MANAGED_WALLET_ENCRYPTION_KEY is supplied.
    #
    # OUTSIDE TEST THIS IS MANDATORY AND ITS ABSENCE IS A HARD RAISE. These
    # ciphertexts are users' managed-wallet PRIVATE KEYS; deriving from the
    # wrong material would not fail loudly, it would fail to decrypt real
    # wallets -- or, on the encrypt side, seal them under a key we then throw
    # away. Previously this read `.secret_key_base[0, 32]` with no guard at
    # all, so a missing RAILS_MASTER_KEY surfaced as `undefined method [] for
    # nil` rather than as the credential error it is.
    #
    # Under Rails.env.test? ONLY, fall back to a fixed non-secret string so the
    # legacy-compatibility tests run without RAILS_MASTER_KEY.
    def self.legacy_secret_key_base
      material = Rails.application.credentials.secret_key_base.presence
      return material if material
      return TEST_SECRET_KEY_BASE if Rails.env.test?

      raise "RAILS_MASTER_KEY required: credentials.secret_key_base is unavailable, " \
            "so managed-wallet keys can be neither encrypted nor decrypted"
    end
    private_class_method :legacy_secret_key_base
  end
end
