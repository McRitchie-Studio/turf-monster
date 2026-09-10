require "test_helper"

class Solana::KeypairTest < ActiveSupport::TestCase
  # OPSEC-015 — managed-wallet private keys are encrypted at rest with a
  # version-tagged scheme. These tests cover the v2 roundtrip, backward
  # decryption of legacy untagged ciphertexts, and the reencrypt migration
  # path that `solana:reencrypt_managed_wallets` drives.

  # Reproduce the pre-OPSEC-015 ciphertext format: AES over the first 32
  # CHARS of the hex secret_key_base, Base64'd bytes, NO version prefix.
  #
  # Derives the key material here rather than calling the production accessor,
  # so this stays an INDEPENDENT reproduction of the legacy format. When
  # RAILS_MASTER_KEY is present (dev, and CI's own runs) it uses the real
  # secret_key_base exactly as before; it falls back only when credentials
  # cannot decrypt, which is the case on Dependabot PRs -- they run against the
  # Dependabot secret store and cannot see repository secrets.
  def legacy_key_material
    Rails.application.credentials.secret_key_base.presence ||
      Solana::Keypair::TEST_SECRET_KEY_BASE
  end

  def legacy_ciphertext_for(keypair)
    enc = ActiveSupport::MessageEncryptor.new(legacy_key_material[0, 32])
    enc.encrypt_and_sign(Base64.strict_encode64(keypair.to_bytes))
  end

  test "v2 encrypt/decrypt roundtrips to the same keypair" do
    original = Solana::Keypair.generate
    ciphertext = original.encrypt

    assert ciphertext.start_with?("v2:"), "ciphertext must carry the v2 version tag"
    restored = Solana::Keypair.from_encrypted(ciphertext)
    assert_equal original.to_base58, restored.to_base58
    assert_equal original.to_bytes, restored.to_bytes
  end

  test "current_version? distinguishes v2 from legacy ciphertexts" do
    keypair = Solana::Keypair.generate
    assert Solana::Keypair.current_version?(keypair.encrypt)
    assert_not Solana::Keypair.current_version?(legacy_ciphertext_for(keypair))
    assert_not Solana::Keypair.current_version?(nil)
    assert_not Solana::Keypair.current_version?("")
  end

  test "from_encrypted still decrypts legacy untagged ciphertexts" do
    original = Solana::Keypair.generate
    legacy = legacy_ciphertext_for(original)

    restored = Solana::Keypair.from_encrypted(legacy)
    assert_equal original.to_base58, restored.to_base58
    assert_equal original.to_bytes, restored.to_bytes
  end

  test "reencrypt migrates a legacy ciphertext to v2 without changing the key" do
    original = Solana::Keypair.generate
    legacy = legacy_ciphertext_for(original)
    assert_not Solana::Keypair.current_version?(legacy)

    migrated = Solana::Keypair.reencrypt(legacy)

    assert Solana::Keypair.current_version?(migrated), "reencrypt must produce a v2 ciphertext"
    assert_equal original.to_base58, Solana::Keypair.from_encrypted(migrated).to_base58
  end

  test "reencrypt is idempotent for already-current ciphertexts" do
    original = Solana::Keypair.generate
    migrated = Solana::Keypair.reencrypt(original.encrypt)

    assert Solana::Keypair.current_version?(migrated)
    assert_equal original.to_base58, Solana::Keypair.from_encrypted(migrated).to_base58
  end

  test "from_encrypted raises on a corrupt ciphertext" do
    assert_raises(ActiveSupport::MessageEncryptor::InvalidMessage) do
      Solana::Keypair.from_encrypted("v2:not-a-real-ciphertext")
    end
  end
end
