require "test_helper"

# managed-wallet-key-rotation — the two-key READ window on Solana::Keypair.
#
#   MANAGED_WALLET_ENCRYPTION_KEY           seals, and opens
#   MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS  opens only (the key being retired)
#
# Until this landed, Keypair read ONE key and memoized it, so a rotation had no
# window: the moment the env var changed, every stored wallet stopped opening.
#
# Keys are generated per test and are throwaway. Ciphertexts are sealed by an
# independent restatement of the v2 envelope, so "this opens under key B" is
# never answered by the code under test. Comparisons are `assert a == b, msg`
# so a failure never prints a secret, even a throwaway one.
class Solana::KeypairRotationTest < ActiveSupport::TestCase
  KEY_ENV      = "MANAGED_WALLET_ENCRYPTION_KEY".freeze
  PREVIOUS_ENV = "MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS".freeze
  V2_KDF_LABEL = "turf-monster managed wallet v2".freeze

  setup do
    @key_a = SecureRandom.hex(32) # the OLD key
    @key_b = SecureRandom.hex(32) # the NEW key
    @keypair = Solana::Keypair.generate
  end

  def v2_encryptor(material)
    @v2_encryptors ||= {}
    @v2_encryptors[material] ||= ActiveSupport::MessageEncryptor.new(
      ActiveSupport::KeyGenerator.new(material).generate_key(V2_KDF_LABEL, 32)
    )
  end

  def seal(material, keypair)
    "v2:#{v2_encryptor(material).encrypt_and_sign(Base64.strict_encode64(keypair.to_bytes))}"
  end

  def opens_under?(material, ciphertext, keypair)
    return false unless ciphertext.to_s.start_with?("v2:")

    v2_encryptor(material).decrypt_and_verify(ciphertext.delete_prefix("v2:")) ==
      Base64.strict_encode64(keypair.to_bytes)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    false
  end

  # Clears every memoized encryptor on the way in and restores on the way out,
  # so the key under test is the one THIS block set -- not a sibling's memo.
  def with_wallet_keys(primary:, previous: nil)
    saved_env = { KEY_ENV => ENV[KEY_ENV], PREVIOUS_ENV => ENV[PREVIOUS_ENV] }
    memo_ivars = Solana::Keypair.instance_variables - [:@admin]
    saved_memos = memo_ivars.to_h { |iv| [iv, Solana::Keypair.instance_variable_get(iv)] }
    memo_ivars.each { |iv| Solana::Keypair.instance_variable_set(iv, nil) }
    { KEY_ENV => primary, PREVIOUS_ENV => previous }.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    (Solana::Keypair.instance_variables - [:@admin]).each do |iv|
      Solana::Keypair.instance_variable_set(iv, saved_memos.fetch(iv, nil))
    end
  end

  def same_wallet?(a, b) = a.to_bytes == b.to_bytes

  # --- decrypt falls back across both keys ------------------------------------

  test "from_encrypted opens a row sealed under the PREVIOUS key while the new key is current" do
    old_row = seal(@key_a, @keypair)
    with_wallet_keys(primary: @key_b, previous: @key_a) do
      assert same_wallet?(Solana::Keypair.from_encrypted(old_row), @keypair),
             "an old-key row must stay readable for the whole rotation window"
    end
  end

  test "from_encrypted opens a row sealed under the CURRENT key" do
    new_row = seal(@key_b, @keypair)
    with_wallet_keys(primary: @key_b, previous: @key_a) do
      assert same_wallet?(Solana::Keypair.from_encrypted(new_row), @keypair)
    end
  end

  test "from_encrypted still raises InvalidMessage when no configured key opens the row" do
    stray = seal(SecureRandom.hex(32), @keypair)
    with_wallet_keys(primary: @key_b, previous: @key_a) do
      assert_raises(ActiveSupport::MessageEncryptor::InvalidMessage) { Solana::Keypair.from_encrypted(stray) }
    end
  end

  test "without a previous key, an old-key row does not open -- the window is the only way across" do
    old_row = seal(@key_a, @keypair)
    with_wallet_keys(primary: @key_b, previous: nil) do
      assert_raises(ActiveSupport::MessageEncryptor::InvalidMessage) { Solana::Keypair.from_encrypted(old_row) }
    end
  end

  test "an EMPTY previous key is no key at all" do
    old_row = seal(@key_a, @keypair)
    with_wallet_keys(primary: @key_b, previous: "") do
      assert_not Solana::Keypair.previous_key_configured?
      assert_raises(ActiveSupport::MessageEncryptor::InvalidMessage) { Solana::Keypair.from_encrypted(old_row) }
    end
  end

  # --- only the current key seals ----------------------------------------------

  test "encrypt seals under the CURRENT key, never the previous one" do
    with_wallet_keys(primary: @key_b, previous: @key_a) do
      sealed = @keypair.encrypt
      assert opens_under?(@key_b, sealed, @keypair), "a new ciphertext must open under the current key"
      assert_not opens_under?(@key_a, sealed, @keypair), "a new ciphertext must never be sealed under the retiring key"
    end
  end

  test "seal_plaintext re-seals the exact plaintext under the current key" do
    plaintext = Base64.strict_encode64(@keypair.to_bytes)
    with_wallet_keys(primary: @key_b, previous: @key_a) do
      sealed = Solana::Keypair.seal_plaintext(plaintext)
      assert opens_under?(@key_b, sealed, @keypair)
    end
  end

  # --- open_plaintext: the question a prefix cannot answer -----------------------

  test "open_plaintext with keys [:current] does NOT fall back to the previous key" do
    old_row = seal(@key_a, @keypair)
    with_wallet_keys(primary: @key_b, previous: @key_a) do
      assert_nil Solana::Keypair.open_plaintext(old_row, keys: [:current]),
                 "an old-key row must not read as current -- that is the whole defect"
      assert Solana::Keypair.open_plaintext(old_row, keys: [:previous]) ==
             Base64.strict_encode64(@keypair.to_bytes), "the previous key must open its own row"
    end
  end

  test "open_plaintext with keys [:previous] is nil when no previous key is configured" do
    old_row = seal(@key_a, @keypair)
    with_wallet_keys(primary: @key_b, previous: nil) do
      assert_nil Solana::Keypair.open_plaintext(old_row, keys: [:previous])
    end
  end

  test "open_plaintext never hands a v2 payload to the legacy key or a legacy payload to a v2 key" do
    legacy_material = Rails.application.credentials.secret_key_base.presence || Solana::Keypair::TEST_SECRET_KEY_BASE
    legacy_row = ActiveSupport::MessageEncryptor.new(legacy_material[0, 32])
                                                .encrypt_and_sign(Base64.strict_encode64(@keypair.to_bytes))
    v2_row = seal(@key_b, @keypair)
    with_wallet_keys(primary: @key_b, previous: @key_a) do
      assert_nil Solana::Keypair.open_plaintext(v2_row, keys: [:legacy])
      assert_nil Solana::Keypair.open_plaintext(legacy_row, keys: %i[current previous])
      assert Solana::Keypair.open_plaintext(legacy_row, keys: [:legacy]).present?
    end
  end

  test "open_plaintext refuses a key name it does not know" do
    assert_raises(ArgumentError) { Solana::Keypair.open_plaintext("v2:x", keys: [:newest]) }
  end

  test "current_version? is a FORMAT check: an old-key row still answers true" do
    # Pinned so nobody mistakes it for a key check again -- the old migration
    # did, and skipped every row after a key change.
    assert Solana::Keypair.current_version?(seal(@key_a, @keypair))
    assert Solana::Keypair.current_version?(seal(@key_b, @keypair))
  end

  test "reset_encryptors! makes the next read re-derive from the environment" do
    row_b = seal(@key_b, @keypair)
    with_wallet_keys(primary: @key_a, previous: nil) do
      Solana::Keypair.encrypt_value("warm the memo")
      ENV[KEY_ENV] = @key_b
      Solana::Keypair.reset_encryptors!
      assert same_wallet?(Solana::Keypair.from_encrypted(row_b), @keypair),
             "after a reset the memo must not answer for the key that was replaced"
    end
  end
end
