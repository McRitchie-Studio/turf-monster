require "test_helper"

# Unit — Tokens::LevelUpGrant is the payout behind the level-up modal's
# "your Free Entry Token is minting now". What it must get right:
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
  # The ref the grant will build for THIS user's earning wallet on THIS
  # deployment. Tests assert through the helper rather than hard-coding the
  # shape, so the scheme can change in one place — which is exactly what
  # happened when the ref moved off users.id.
  def ref_for(level, user: @user)
    Tokens::LevelUpGrant.source_ref(user.solana_address, level)
  end

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
    assert_equal [ref_for(2)], vault.mint_calls
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
    assert_equal [ref_for(2), ref_for(3), ref_for(4)],
      vault.mint_calls, "must mint in ascending level order"
    assert_equal 4, @user.reload.entry_tokens_granted_level
  end

  test "grants only the levels not already on-chain" do
    vault = vault_for(seeds: 300, tokens: [token(ref_for(2))])

    result = Tokens::LevelUpGrant.call(@user, vault: vault)

    assert_equal [3, 4], result.minted_levels, "level 2 is already paid — skip it"
    assert_equal [ref_for(3), ref_for(4)], vault.mint_calls
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
    wallet = @user.solana_address
    assert_equal Tokens::LevelUpGrant.source_ref(wallet, 2),
                 Tokens::LevelUpGrant.source_ref(wallet, 2)
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

  test "returns an explicit unevaluable result when the on-chain account is missing" do
    vault = FakeVault.new
    def vault.sync_balance(_wallet) = nil

    result = Tokens::LevelUpGrant.call(@user, vault: vault)

    refute result.evaluated?, "missing chain state is not the same as nothing owed"
    assert_equal :user_account_missing, result.unevaluable_reason
    assert_match(/no UserAccount PDA/, result.unevaluable_message)
    assert_empty vault.mint_calls
    assert_equal 1, @user.reload.entry_tokens_granted_level,
      "the waterline must NOT advance on a read we could not make"
  end

  test "returns an explicit unevaluable result for a user with no wallet" do
    vault = vault_for(seeds: 500)

    result = Tokens::LevelUpGrant.call(users(:jordan), vault: vault)

    refute result.evaluated?
    assert_equal :no_wallet, result.unevaluable_reason
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
      token(ref_for(2)),
      token(ref_for(5, user: users(:alex))), # another WALLET's grant
      token("levelup:qa:#{Tokens::LevelUpGrant.wallet_key(@user.solana_address)}:7"), # same wallet, ANOTHER DEPLOYMENT
      token("stripe:42:0"),
      token("operator:#{@user.id}:deadbeef")
    ]

    assert_equal Set[2], Tokens::LevelUpGrant.granted_levels(@user.solana_address, tokens),
      "only THIS wallet's refs on THIS deployment count — another wallet's grant, the " \
      "same wallet's grant on another deployment, and other rails all match nothing"
  end

  # ── THE COLLISION THE REF SCHEME EXISTS TO CLOSE ──────────────────────────
  #
  # Solana::Vault#entry_token_pda derives the account from sha256(source_ref)
  # under the program id ALONE — there is no wallet in the seeds, and
  # mint_entry_token's own contract says the ref must be globally unique ACROSS
  # WALLETS. The first version of this service keyed it on users.id, and
  # SOLANA_PROGRAM_ID defaults to the SAME devnet program for development, test
  # and QA. So QA user 7 at level 2 and a local dev user 7 at level 2 derived ONE
  # account: the loser's mint raises 0x0 forever and pages an ErrorLog every 15
  # minutes with no path to payment. The PDAs outlive the database, so a QA reset
  # reproduces it wholesale.

  test "two different WALLETS never share a ref at the same level" do
    a = Tokens::LevelUpGrant.source_ref("4MCkYMrLCVXap9jW1pL8kDyNNtgWF19WGp6B5m1TVsCr", 2)
    b = Tokens::LevelUpGrant.source_ref("14Gn2cCA69PwKU7t8x1fS6WQwBPnwXkSA4KRM8ibmBP4", 2)

    assert_not_equal a, b,
      "same level, different wallets — an equal ref here is one on-chain account for two " \
      "users, and the second mint can never succeed"
  end

  test "two DEPLOYMENTS never share a ref for the same wallet and level" do
    wallet = @user.solana_address
    qa  = Tokens::LevelUpGrant.source_ref(wallet, 2, namespace: "qa")
    dev = Tokens::LevelUpGrant.source_ref(wallet, 2, namespace: "development")

    assert_not_equal qa, dev,
      "dev, test and QA share ONE devnet program by design, so the deployment must be in " \
      "the ref or one environment's mint permanently blocks another's"
  end

  # The property the namespace must NOT cost us: determinism is what makes a
  # Sidekiq retry a harmless init collision instead of a second token.
  test "the ref is still deterministic for one wallet, level and deployment" do
    wallet = @user.solana_address
    assert_equal Tokens::LevelUpGrant.source_ref(wallet, 3, namespace: "qa"),
                 Tokens::LevelUpGrant.source_ref(wallet, 3, namespace: "qa")
  end

  test "the ref fits the on-chain 64-byte field at the LONGEST deployment name" do
    # padded_source_ref RAISES past 64 rather than truncating, so an overflow is
    # a hard failure at mint time. A base58 address is up to 44 chars, which is
    # why the wallet is hashed rather than inlined.
    ref = Tokens::LevelUpGrant.source_ref("4MCkYMrLCVXap9jW1pL8kDyNNtgWF19WGp6B5m1TVsCr",
                                          9999, namespace: "development")

    assert_operator ref.bytesize, :<=, 64, "ref would overflow the [u8;64] field: #{ref}"
  end

  # ── THE COMBO ACCOUNT ─────────────────────────────────────────────────────
  #
  # A managed account that later links Phantom has TWO addresses. The ref must
  # follow the wallet actually being minted to — the one #call read the balance
  # from and lists tokens on — not a re-read of User#solana_address, which
  # prefers web3 and would key the ref to a different wallet than the payout.

  test "the ref follows the EARNING wallet, not a re-read of the user record" do
    wallet = @user.solana_address
    vault  = vault_for(seeds: 100)

    Tokens::LevelUpGrant.call(@user, vault: vault)

    assert_equal [Tokens::LevelUpGrant.source_ref(wallet, 2)], vault.mint_calls,
      "the minted ref must be derived from the wallet the token was minted TO"
    assert_equal [wallet], vault.mint_wallets.uniq,
      "and it must be the same wallet the balance was read from"
  end

  test "a wallet with a grant on another deployment is still owed one here" do
    wallet = @user.solana_address
    elsewhere = token(Tokens::LevelUpGrant.source_ref(wallet, 2, namespace: "qa"))
    vault = vault_for(seeds: 200, tokens: [elsewhere])

    result = Tokens::LevelUpGrant.new(@user, vault: vault).call

    assert_includes result.minted_levels, 2,
      "a QA grant must not satisfy a development payout — different program state entirely"
  end
end
