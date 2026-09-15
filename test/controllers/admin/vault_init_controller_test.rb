require "test_helper"

class Admin::VaultInitControllerTest < ActionDispatch::IntegrationTest
  # Three real-looking base58 pubkeys for happy-path validation. Pulled
  # from turf-vault/docs/CURRENT_DEPLOYMENT.md so the fixtures stay aligned
  # with the documented signer set.
  # An ARBITRARY realistic pubkey filling signer slot 0 in these fixtures. It is
  # the legacy pre-rotation wallet, kept because nothing here asserts against the
  # live set — do not read it as one. The comment this replaces claimed it
  # "mirrors the on-chain signer set"; docs/SOLANA.md re-verified that set
  # on-chain on 2026-09-05 as 8K81w4e6… on BOTH devnet and mainnet, so the claim
  # was false. The identity itself is named Xan (renamed from "Alex Bot"
  # 2026-09-15); it was never "Alex", which is Mr. McRitchie.
  XAN_LEGACY = "F6f8h5yynbnkgWvU5abQx3RJxJpe8EoQmeFBuNKdKzhZ".freeze
  ALEX     = Admin::VaultInitController::INIT_AUTHORITY # human (Mr. McRitchie) "7ZDJp7…r2J"
  MASON    = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR".freeze
  SIGNERS  = [XAN_LEGACY, ALEX, MASON].freeze
  # v0.16 added treasury_authority as a 4th initialize arg (pinned to the
  # Squads vault PDA — same one that holds the program upgrade authority).
  TREASURY = "BW13kgfiG2koFn3WRkte21NW9TFygsD1ge2fNJdjH6kC".freeze

  setup do
    @admin = users(:alex)
    @user  = users(:jordan)
  end

  # --- require_admin gate (before_action halts before any RPC) ---

  test "show redirects non-admins" do
    log_in_as(@user)
    get admin_vault_init_path
    assert_response :redirect
  end

  test "build redirects non-admins (no RPC reached)" do
    log_in_as(@user)
    post admin_build_vault_init_path, params: {}, as: :json
    assert_response :redirect
  end

  test "confirm redirects non-admins (no RPC reached)" do
    log_in_as(@user)
    post admin_confirm_vault_init_path, params: {}, as: :json
    assert_response :redirect
  end

  test "show redirects when logged out" do
    get admin_vault_init_path
    assert_response :redirect
  end

  # --- DEFAULT_SIGNERS derives Alex from INIT_AUTHORITY (single source of truth) ---

  test "DEFAULT_SIGNERS[1] is derived from INIT_AUTHORITY constant" do
    assert_equal Admin::VaultInitController::INIT_AUTHORITY,
                 Admin::VaultInitController::DEFAULT_SIGNERS[1]
  end

  test "DEFAULT_SIGNERS contains exactly three distinct base58 pubkeys" do
    set = Admin::VaultInitController::DEFAULT_SIGNERS
    assert_equal 3, set.length
    assert_equal 3, set.uniq.length
    set.each { |s| assert_equal 32, Solana::Keypair.decode_base58(s).bytesize }
  end

  # --- validate_init_params! — direct unit tests via .send ---
  #
  # The private method runs before any Solana RPC, so we can exercise every
  # rejection path without touching the network. All happy-path values are
  # real base58 pubkeys taken from SIGNERS above.

  def ctrl
    @ctrl ||= Admin::VaultInitController.new
  end

  def validate!(creator: ALEX, signers: SIGNERS, threshold: 2, treasury: TREASURY)
    ctrl.send(:validate_init_params!, creator, signers, threshold, treasury)
  end

  test "validate: happy path" do
    assert_nothing_raised { validate! }
  end

  test "validate: rejects blank creator" do
    assert_raises_with_message("creator_pubkey required") { validate!(creator: "") }
  end

  test "validate: rejects blank signer slot" do
    assert_raises_with_message("Three signer addresses required") {
      validate!(signers: [XAN_LEGACY, "", MASON])
    }
  end

  test "validate: rejects invalid base58 creator" do
    assert_raises_with_message(/Invalid pubkey/) { validate!(creator: "not-base58!@#") }
  end

  test "validate: rejects invalid base58 signer" do
    assert_raises_with_message(/Invalid pubkey/) {
      validate!(signers: [XAN_LEGACY, "not-base58!@#", MASON])
    }
  end

  test "validate: base58 check runs BEFORE distinctness (Low-1 fix)" do
    # Three identical garbage strings should report the invalid pubkey, not
    # 'must be distinct' — pre-fix that error message was misleading.
    err = assert_raises(RuntimeError) {
      validate!(creator: "garbage", signers: %w[garbage garbage garbage])
    }
    assert_match(/Invalid pubkey/, err.message)
    refute_match(/distinct/, err.message)
  end

  test "validate: rejects duplicate signers" do
    assert_raises_with_message("Signers must be distinct") {
      validate!(signers: [XAN_LEGACY, XAN_LEGACY, MASON], creator: XAN_LEGACY)
    }
  end

  test "validate: rejects threshold below 1" do
    assert_raises_with_message(/Threshold must be 1, 2, or 3/) { validate!(threshold: 0) }
  end

  test "validate: rejects threshold above 3" do
    assert_raises_with_message(/Threshold must be 1, 2, or 3/) { validate!(threshold: 4) }
  end

  test "validate: rejects creator not in signer set" do
    # `11111…112` is the System Program pubkey — guaranteed valid base58 but
    # not in our signer set.
    assert_raises_with_message(/creator_pubkey must be one of the signers/) {
      validate!(creator: "11111111111111111111111111111112")
    }
  end

  test "validate: enforces creator == INIT_AUTHORITY on mainnet" do
    with_mainnet do
      assert_raises_with_message(/must equal INIT_AUTHORITY/) {
        validate!(creator: XAN_LEGACY, signers: [XAN_LEGACY, MASON, ALEX], threshold: 2)
      }
    end
  end

  test "validate: passes on mainnet when creator == INIT_AUTHORITY" do
    with_mainnet do
      assert_nothing_raised { validate! }
    end
  end

  test "validate: does not enforce INIT_AUTHORITY off-mainnet (creator can be any signer)" do
    # Default config is devnet — the bot as creator is fine there.
    assert_nothing_raised {
      validate!(creator: XAN_LEGACY, signers: [XAN_LEGACY, MASON, ALEX], threshold: 2)
    }
  end

  # --- vault_uninitialized? cache behavior ---

  test "uninitialized_cache_key is namespaced by PROGRAM_ID" do
    key = Admin::VaultInitController.uninitialized_cache_key
    assert_includes key, Solana::Config::PROGRAM_ID
    assert key.start_with?("vault_init:uninitialized:")
  end

  test "vault_uninitialized? returns false (fail-safe) when Vault raises" do
    # Stub Solana::Vault.new to raise — vault_uninitialized? must catch and
    # return false so an RPC blip never breaks navbar render.
    Rails.cache.delete(Admin::VaultInitController.uninitialized_cache_key)
    original = Solana::Vault.method(:new)
    Solana::Vault.define_singleton_method(:new) { |*| raise "RPC down" }
    begin
      refute Admin::VaultInitController.vault_uninitialized?
    ensure
      Solana::Vault.define_singleton_method(:new, original)
    end
  end

  private

  def assert_raises_with_message(expected, &block)
    err = assert_raises(RuntimeError, &block)
    if expected.is_a?(Regexp)
      assert_match expected, err.message
    else
      assert_equal expected, err.message
    end
  end

  # Temporarily report mainnet from Solana::Config. Pure singleton-method
  # swap — no env-var mutation, no flag in the module.
  def with_mainnet
    original = Solana::Config.method(:mainnet?)
    Solana::Config.define_singleton_method(:mainnet?) { true }
    yield
  ensure
    Solana::Config.define_singleton_method(:mainnet?, original)
  end
end
