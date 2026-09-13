# Rails-specific extensions to Solana::Keypair (from the solana-studio gem).
# Adds admin keypair loading + versioned encrypt/decrypt for DB storage.
#
# OPSEC-015 — managed-wallet private keys are encrypted at rest in
# users.encrypted_web2_solana_private_key. The key material now comes from
# MANAGED_WALLET_ENCRYPTION_KEY (a dedicated env var, independent of
# RAILS_MASTER_KEY / secret_key_base) run through ActiveSupport::KeyGenerator
# for a full 256-bit AES key. Ciphertexts are version-tagged ("v2:") so the
# SCHEME is recognisable: `from_encrypted` still decrypts legacy untagged
# ciphertexts via the old secret_key_base derivation.
#
# Pre-OPSEC-015 the key was `secret_key_base[0, 32]` — 32 hex *characters*,
# i.e. only ~128 bits of real entropy, and impossible to rotate without
# orphaning every stored wallet key.
#
# KEY ROTATION (managed-wallet-key-rotation) — the two-key window.
#
#   MANAGED_WALLET_ENCRYPTION_KEY           seals every new ciphertext, and opens
#   MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS  opens only — the key being retired
#
# The "v2:" tag names the SCHEME, never the KEY: every row sealed under the old
# key and every row sealed under the new one reads "v2:". So a v2 payload is
# opened by TRIAL, current key first, then the previous key. That is safe only
# because the scheme is authenticated — AES-256-GCM under this app's
# `load_defaults 8.1` — so a wrong key raises InvalidMessage instead of
# returning bytes (measured 2026-09-10: 2000 of 2000 wrong-key trials raised).
# No key identifier is stamped into the ciphertext on purpose: the defect this
# window replaces WAS a label trusted as proof of a key. Whether a row is
# readable under the new key is answered only by opening it with that key.
#
# `bin/rails solana:reencrypt_managed_wallets` walks every row onto the current
# key and verifies each one under the current key ALONE before writing it (see
# Solana::ManagedWalletRotation). The previous key may be retired only after
# `bin/rails solana:verify_managed_wallet_keys` counts every row readable
# without it.

module Solana
  class Keypair
    ENCRYPTION_VERSION = "v2".freeze

    # The two-key window (see the header). KEY_ENV seals and opens; PREVIOUS
    # only opens, and only while a rotation is in flight.
    KEY_ENV = "MANAGED_WALLET_ENCRYPTION_KEY".freeze
    PREVIOUS_KEY_ENV = "MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS".freeze

    # KeyGenerator label for the v2 AES key. Changing it orphans every row.
    V2_KDF_LABEL = "turf-monster managed wallet v2".freeze

    # Every key that may OPEN a stored ciphertext, in trial order. Only
    # :current ever seals. A v2 payload is tried against :current and
    # :previous; an untagged payload only ever against :legacy.
    OPENING_KEYS = %i[current previous legacy].freeze

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
    # (under the current key OR, during a rotation, the previous one) and
    # legacy untagged ciphertexts transparently. Raises InvalidMessage when no
    # accepted key opens it — the same error a single-key read always raised.
    def self.from_encrypted(encrypted_string)
      plaintext = open_plaintext(encrypted_string, keys: OPENING_KEYS)
      raise ActiveSupport::MessageEncryptor::InvalidMessage if plaintext.nil?

      from_bytes(Base64.strict_decode64(plaintext))
    end

    # The stored plaintext (Base64 of the 64-byte secret) of a ciphertext,
    # opened ONLY with the named keys, or nil when none of them opens it.
    #
    # This is the primitive the rotation is built on: `keys: [:current]` asks
    # "is this row readable under the new key alone?" — the one question a
    # "v2:" prefix cannot answer. Only InvalidMessage (wrong key, or a
    # tampered/corrupt payload) means "not this key"; anything else raises.
    # The plaintext is returned, never logged — callers must keep it that way.
    def self.open_plaintext(encrypted_string, keys:)
      unknown = keys - OPENING_KEYS
      raise ArgumentError, "unknown managed-wallet key(s): #{unknown.inspect}" if unknown.any?

      version, payload = parse_encrypted(encrypted_string)
      keys.each do |name|
        encryptor = opening_encryptor(name, version)
        next if encryptor.nil?

        begin
          plaintext = encryptor.decrypt_and_verify(payload)
        rescue ActiveSupport::MessageEncryptor::InvalidMessage
          next
        end
        return plaintext if plaintext.is_a?(String)
      end
      nil
    end

    # Encrypt for DB storage — always produces a current-version ciphertext.
    def encrypt
      self.class.encrypt_value(to_bytes)
    end

    def self.encrypt_value(bytes)
      seal_plaintext(Base64.strict_encode64(bytes))
    end

    # Seal an already-encoded plaintext under the CURRENT key. The rotation
    # re-seals the exact plaintext the old key opened, byte for byte, rather
    # than re-deriving it from a Keypair — the envelope changes, the secret
    # never does.
    def self.seal_plaintext(plaintext)
      "#{ENCRYPTION_VERSION}:#{current_encryptor.encrypt_and_sign(plaintext)}"
    end

    # Re-encrypt a stored ciphertext under the current key: open it with any
    # accepted key, return a fresh current-key ciphertext. It does NOT verify
    # and does NOT write — solana:reencrypt_managed_wallets does both, per row,
    # through Solana::ManagedWalletRotation.
    def self.reencrypt(encrypted_string)
      from_encrypted(encrypted_string).encrypt
    end

    # True if a ciphertext carries the current SCHEME tag. This is a FORMAT
    # check and says NOTHING about which key sealed it: after a key change
    # every row still answers true. Never use it to decide a row is done —
    # that exact mistake made the old migration skip every row and exit 0.
    def self.current_version?(encrypted_string)
      encrypted_string.to_s.start_with?("#{ENCRYPTION_VERSION}:")
    end

    # True when a rotation is in flight: the previous key is configured.
    def self.previous_key_configured?
      ENV[PREVIOUS_KEY_ENV].present?
    end

    # Drop every memoized encryptor so the next use re-derives from ENV.
    # Config changes on Heroku restart the dyno, so production never needs
    # this; the rotation calls it once at start so it can never be answered
    # by an encryptor derived before the environment it is checking.
    def self.reset_encryptors!
      @current_encryptor = nil
      @previous_encryptor = nil
      @legacy_encryptor = nil
    end

    def self.parse_encrypted(s)
      if current_version?(s)
        [ENCRYPTION_VERSION, s.delete_prefix("#{ENCRYPTION_VERSION}:")]
      else
        [:legacy, s]
      end
    end
    private_class_method :parse_encrypted

    # The encryptor a named key opens a payload of this version with, or nil
    # when that key cannot apply (not configured, or the wrong scheme). A v2
    # payload is never handed to the legacy key, nor a legacy one to a v2 key.
    def self.opening_encryptor(name, version)
      if version == :legacy
        name == :legacy ? legacy_encryptor : nil
      elsif version == ENCRYPTION_VERSION
        case name
        when :current  then current_encryptor
        when :previous then previous_encryptor
        end
      else
        raise "unknown managed-wallet encryption version: #{version.inspect}"
      end
    end
    private_class_method :opening_encryptor

    # Current scheme: 256-bit key derived from MANAGED_WALLET_ENCRYPTION_KEY
    # via KeyGenerator (PBKDF2 + domain-separation label). In production the
    # env var is mandatory — config/initializers/managed_wallet_encryption.rb
    # fails the boot if it's missing. Dev/test/CI fall back to secret_key_base
    # run through the SAME KDF: still a proper 256-bit key, just not
    # rotation-isolated (acceptable off-prod).
    def self.current_encryptor
      @current_encryptor ||= v2_encryptor(ENV[KEY_ENV].presence || legacy_secret_key_base)
    end
    private_class_method :current_encryptor

    # The key being retired, during a rotation only: MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS,
    # through the SAME KDF as the current key — it is simply the value the
    # current key used to be. Opens, never seals. nil when unset or empty, so
    # an empty assignment can never become a key.
    def self.previous_encryptor
      @previous_encryptor ||= begin
        material = ENV[PREVIOUS_KEY_ENV].presence
        material && v2_encryptor(material)
      end
    end
    private_class_method :previous_encryptor

    # One v2 encryptor from raw key material. The single definition of the v2
    # key derivation — the current and previous keys both come through here.
    def self.v2_encryptor(material)
      key = ActiveSupport::KeyGenerator.new(material).generate_key(V2_KDF_LABEL, 32)
      ActiveSupport::MessageEncryptor.new(key)
    end
    private_class_method :v2_encryptor

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
