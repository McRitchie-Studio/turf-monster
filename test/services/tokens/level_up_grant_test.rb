require "test_helper"

# Unit — Tokens::LevelUpGrant is the payout behind the level-up modal's
# "your Free Entry Token will arrive in 48 hours". What it must get right:
#   - one token per level milestone, lowest level first
#   - a DETERMINISTIC source_ref, because that is the ONLY thing standing
#     between a Sidekiq retry and a double-grant
#   - never paying over an operator's manual /admin/free_entries mint
#   - never advancing its waterline past a level that was not actually minted
class Tokens::LevelUpGrantTest < ActiveSupport::TestCase
  setup do
    @user = users(:sam) # web3_solana_address fixture → solana_connected?
    @user.update_columns(seeds: 0, level: 1, entry_tokens_granted_level: 1)
  end

  # Builds the token shape decode_entry_token returns — only :source_ref and
  # :consumed matter to the grant.
  def token(source_ref)
    { pda: "pda-#{source_ref}", source_ref: source_ref, source: 0, consumed: false }
  end

  def vault_for(seeds:, tokens: [], fail_after: nil)
    FakeVault.new(tokens: tokens, fail_after: fail_after).tap { |v| v.sync_balance_seeds = seeds }
  end

  # --- the payout itself ---

  test "mints one token when the user crosses their first level" do
    vault = vault_for(seeds: 100)

    result = Tokens::LevelUpGrant.call(@user, vault: vault)

    assert_equal [2], result.minted_levels, "100 seeds is level 2 — exactly one token owed"
    assert_equal ["levelup:#{@user.id}:2"], vault.mint_calls
    assert_equal 2, @user.reload.entry_tokens_granted_level
  end

  test "mints nothing below the first milestone" do
    vault = vault_for(seeds: 99)

    result = Tokens::LevelUpGrant.call(@user, vault: vault)

    assert_empty vault.mint_calls, "99 seeds is still level 1 — nothing is owed"
    assert_equal 0, result.minted_count
    assert_equal 1, @user.reload.entry_tokens_granted_level
  end

  test "backfills every missed milestone at once, lowest level first" do
    vault = vault_for(seeds: 300)

    result = Tokens::LevelUpGrant.call(@user, vault: vault)

    assert_equal [2, 3, 4], result.minted_levels, "300 seeds owes three tokens"
    assert_equal ["levelup:#{@user.id}:2", "levelup:#{@user.id}:3", "levelup:#{@user.id}:4"],
      vault.mint_calls, "must mint in ascending level order"
    assert_equal 4, @user.reload.entry_tokens_granted_level
  end

  test "grants only the levels not already on-chain" do
    vault = vault_for(seeds: 300, tokens: [token("levelup:#{@user.id}:2")])

    result = Tokens::LevelUpGrant.call(@user, vault: vault)

    assert_equal [3, 4], result.minted_levels, "level 2 is already paid — skip it"
    assert_equal ["levelup:#{@user.id}:3", "levelup:#{@user.id}:4"], vault.mint_calls
  end

  # --- idempotency: the property the whole design rests on ---

  test "a second run over the same state mints nothing" do
    first = vault_for(seeds: 200)
    Tokens::LevelUpGrant.call(@user, vault: first)
    assert_equal 2, first.mint_calls.length

    # The chain now holds what the first run minted.
    second = vault_for(seeds: 200, tokens: first.mint_calls.map { |ref| token(ref) })
    result = Tokens::LevelUpGrant.call(@user, vault: second)

    assert_empty second.mint_calls, "re-running must be a no-op, not a second payout"
    assert_equal 0, result.minted_count
  end

  test "the source_ref is deterministic — a retry derives the SAME on-chain PDA" do
    # This is the retry-safety contract in one line. If this ever returns a
    # random component (as Solana::Vault.operator_source_ref does), a lost mint
    # response becomes a duplicate token instead of a harmless init collision.
    assert_equal "levelup:#{@user.id}:2", Tokens::LevelUpGrant.source_ref(@user.id, 2)
    assert_equal Tokens::LevelUpGrant.source_ref(@user.id, 2),
      Tokens::LevelUpGrant.source_ref(@user.id, 2)
  end

  test "the source_ref fits the on-chain [u8;64] field at implausible ids and levels" do
    ref = Tokens::LevelUpGrant.source_ref(999_999_999, 9_999)
    assert_operator ref.b.bytesize, :<=, 64,
      "padded_source_ref RAISES past 64 bytes — the ref must never approach it"
  end

  # --- never pay over the operator ---

  test "does not grant over a manual admin mint for the same milestone" do
    # An operator already minted this user's level-2 token from
    # /admin/free_entries, which carries a RANDOM ref this service cannot match
    # by level. The owed clamp is what stops the second payout.
    vault = vault_for(seeds: 100, tokens: [token("operator:#{@user.id}:a1b2c3d4")])

    result = Tokens::LevelUpGrant.call(@user, vault: vault)

    assert_empty vault.mint_calls, "the admin already paid for level 2 — owed is 0"
    assert_equal 0, result.minted_count
  end

  test "purchased tokens count against owed exactly as the admin page counts them" do
    vault = vault_for(seeds: 200, tokens: [token("stripe:42:0")])

    result = Tokens::LevelUpGrant.call(@user, vault: vault)

    assert_equal 1, result.minted_count,
      "2 levels earned - 1 token already on the wallet = 1 owed"
  end

  test "caps a single run so one wallet cannot drain admin SOL" do
    vault = vault_for(seeds: 100 * (Tokens::LevelUpGrant::MAX_GRANTS_PER_RUN + 3))

    result = Tokens::LevelUpGrant.call(@user, vault: vault)

    assert_equal Tokens::LevelUpGrant::MAX_GRANTS_PER_RUN, result.minted_count
    assert_operator result.skipped, :>, 0, "the remainder must be reported, not silently dropped"
  end

  # --- the waterline must never outrun the chain ---

  test "a failed mint leaves the waterline behind so the next run retries it" do
    # fail_after: 1 → the level-2 mint lands, the level-3 mint raises.
    vault = vault_for(seeds: 300, fail_after: 1)

    result = Tokens::LevelUpGrant.call(@user, vault: vault)

    assert_equal [2], result.minted_levels, "only the mint that landed counts"
    assert_equal 2, @user.reload.entry_tokens_granted_level,
      "the waterline must stop at the last level actually granted"
  end

  test "a gap in granted levels holds the waterline below the gap" do
    # Level 2 missing, level 3 present: the user is still owed level 2, so the
    # row must stay above the sweep's waterline.
    granted = Set[3, 4]
    assert_equal 1, Tokens::LevelUpGrant.contiguous_through(granted),
      "contiguous_through must not report a level whose predecessors are unpaid"
  end

  test "contiguous_through walks an unbroken run" do
    assert_equal 4, Tokens::LevelUpGrant.contiguous_through(Set[2, 3, 4])
  end

  # --- refuse to act on incomplete information ---

  test "returns nil and mints nothing when the on-chain seed read is cold" do
    vault = FakeVault.new
    def vault.sync_balance(_wallet) = nil

    assert_nil Tokens::LevelUpGrant.call(@user, vault: vault),
      "a cold read is 'ask again', never 'nothing was owed'"
    assert_empty vault.mint_calls
    assert_equal 1, @user.reload.entry_tokens_granted_level,
      "the waterline must NOT advance on a read we could not make"
  end

  test "returns nil for a user with no wallet — nowhere to mint to" do
    vault = vault_for(seeds: 500)

    assert_nil Tokens::LevelUpGrant.call(users(:jordan), vault: vault)
    assert_empty vault.mint_calls
  end

  # --- the free side-effect ---

  test "refreshes the denormalized seeds mirror from the live read" do
    vault = vault_for(seeds: 250)

    Tokens::LevelUpGrant.call(@user, vault: vault)

    @user.reload
    assert_equal 250, @user.seeds, "the sweep holds a fresh chain read — keep the mirror honest"
    assert_equal 3, @user.level
  end

  test "granted_levels ignores other users' refs and other rails' tokens" do
    tokens = [
      token("levelup:#{@user.id}:2"),
      token("levelup:#{@user.id + 1}:5"), # another user's grant
      token("stripe:42:0"),
      token("operator:#{@user.id}:deadbeef")
    ]

    assert_equal Set[2], Tokens::LevelUpGrant.granted_levels(@user.id, tokens)
  end
end
