require "test_helper"

# The operator claw-back on /admin/free_entries — "Burn 1" and "Burn all".
#
# What makes this worth its own file rather than a couple of cases bolted onto
# the mint tests: burning is IRREVERSIBLE and mint is not. A mint that fires
# twice collides on `init` and costs some rent; a burn that targets one token too
# many destroys a user's property with no undo. So the tests here are about
# aim and restraint — which tokens the controller picks, which it refuses to
# touch, and what it reports when the chain only half-cooperates.
class Admin::FreeEntriesBurnTest < ActionDispatch::IntegrationTest
  # A token in the shape decode_entry_token returns. `created_at` is
  # load-bearing: a partial burn takes the NEWEST first.
  def token(ref:, created_at:, consumed: false, burned: false, source: 0)
    { pda: "pda-#{ref}", source_ref: ref, source: source,
      consumed: consumed, burned: burned, created_at: created_at,
      consumed_at: consumed ? created_at + 10 : nil }
  end

  setup do
    @admin  = users(:alex)
    @holder = users(:sam)
    @holder.update_columns(seeds: 250, level: 3, slug: "sam-burn-test")
    log_in_as(@admin)
  end

  def vault_holding(*tokens)
    v = FakeVault.new(tokens: tokens)
    v.sync_balance_seeds = 250
    v
  end

  test "Burn 1 takes the NEWEST unspent token and leaves the rest alone" do
    old    = token(ref: "operator:old:1",    created_at: 1_000)
    newest = token(ref: "operator:newest:1", created_at: 3_000)
    middle = token(ref: "operator:middle:1", created_at: 2_000)
    vault  = vault_holding(old, middle, newest)

    Solana::Vault.stub :new, vault do
      post admin_burn_free_entries_path(user_slug: @holder.slug, count: 1)
    end

    assert_equal ["operator:newest:1"], vault.burn_calls,
      "a partial burn claws back the most RECENT grant — the fat-finger an " \
      "operator is undoing is the one just made, never the token the user has " \
      "held since signup"
    refute old[:consumed],    "the oldest token must survive a Burn 1"
    refute middle[:consumed], "the middle token must survive a Burn 1"
  end

  test "Burn all voids every unspent token for that user and nobody else's" do
    mine  = [token(ref: "operator:a:1", created_at: 1_000),
             token(ref: "operator:b:1", created_at: 2_000)]
    yours = [token(ref: "operator:c:1", created_at: 1_500)]

    # jordan carries NO wallet in the fixtures, so keying the other holder's
    # tokens on a nil address would make "nobody else's were touched" true by
    # construction — the assertion would pass against a controller that burned
    # every token on the platform. Give them a real, distinct address.
    other = users(:jordan)
    other.update_columns(slug: "jordan-burn-test",
                         web3_solana_address: "9xQeWvG816bUx9EPa2rHVfjuLKcYSHhFVrGVfKPHeVct")
    assert other.solana_address.present?
    refute_equal @holder.solana_address, other.solana_address

    vault = FakeVault.new(tokens: { @holder.solana_address => mine,
                                    other.solana_address   => yours })
    vault.sync_balance_seeds = 250

    Solana::Vault.stub :new, vault do
      post admin_burn_free_entries_path(user_slug: @holder.slug)
    end

    assert_equal %w[operator:b:1 operator:a:1], vault.burn_calls,
      "Burn all takes every unspent token the named user holds, newest first"
    assert_equal [@holder.solana_address] * 2, vault.burn_wallets
    refute yours.first[:consumed],
      "burning is scoped to ONE user — another holder's tokens must be untouched"
  end

  test "an already-SPENT token is never burned" do
    spent   = token(ref: "operator:spent:1",  created_at: 3_000, consumed: true)
    unspent = token(ref: "operator:live:1",   created_at: 1_000)
    vault   = vault_holding(spent, unspent)

    Solana::Vault.stub :new, vault do
      post admin_burn_free_entries_path(user_slug: @holder.slug)
    end

    # `spent` is the NEWEST, so a controller that sorted without filtering would
    # aim at it first. Burning it would rewrite the history of an entry that
    # exists and stands — and on chain it fails EntryTokenAlreadyConsumed, after
    # the operator has already paid the fee to find out.
    assert_equal ["operator:live:1"], vault.burn_calls,
      "a token already redeemed for a real entry must never be a burn target"
  end

  test "an already-BURNED token is not burned a second time" do
    already = token(ref: "operator:gone:1", created_at: 3_000, consumed: true, burned: true,
                    source: Solana::Vault::ENTRY_TOKEN_BURNED_FLAG)
    live    = token(ref: "operator:live:1", created_at: 1_000)
    vault   = vault_holding(already, live)

    Solana::Vault.stub :new, vault do
      post admin_burn_free_entries_path(user_slug: @holder.slug)
    end

    assert_equal ["operator:live:1"], vault.burn_calls,
      "a re-burn would overwrite consumed_at and destroy the record of WHEN the " \
      "burn happened — the program rejects it, and the page must not attempt it"
  end

  test "nothing to burn is a flash, not a 500" do
    vault = vault_holding(token(ref: "operator:spent:1", created_at: 1_000, consumed: true))

    assert_no_difference -> { ErrorLog.count } do
      Solana::Vault.stub :new, vault do
        post admin_burn_free_entries_path(user_slug: @holder.slug)
      end
    end

    assert_redirected_to admin_free_entries_path
    assert_empty vault.burn_calls
    # A stale row or a double-click is not an incident — say so and move on.
    assert_match(/no unspent free entries/i, flash[:alert].to_s)
  end

  test "a partial failure reports what actually landed" do
    a     = token(ref: "operator:a:1", created_at: 1_000)
    b     = token(ref: "operator:b:1", created_at: 2_000)
    vault = vault_holding(a, b)
    vault.fail_burn_for("operator:a:1")   # the OLDER one — burned second

    Solana::Vault.stub :new, vault do
      post admin_burn_free_entries_path(user_slug: @holder.slug)
    end

    # The honest report is the point. Aborting the batch on the first failure
    # would leave the operator guessing which tokens went; claiming "burned 2"
    # would be a lie about destroyed property.
    assert b[:consumed],  "the burn that succeeded must stand"
    refute a[:consumed],  "the burn that failed must not be reported as done"
    assert_match(/burned 1 free entry/i, flash[:notice].to_s)
    assert_match(/1 burn\(s\) failed/i,  flash[:alert].to_s)
  end

  test "a total failure raises so it is logged as an incident" do
    vault = vault_holding(token(ref: "operator:a:1", created_at: 1_000))
    vault.raise_on_burn = StandardError.new("rpc down")

    Solana::Vault.stub :new, vault do
      assert_raises(StandardError) do
        post admin_burn_free_entries_path(user_slug: @holder.slug)
      end
    end
  end

  test "a non-admin cannot burn" do
    vault = vault_holding(token(ref: "operator:a:1", created_at: 1_000))
    log_in_as(users(:sam))

    Solana::Vault.stub :new, vault do
      post admin_burn_free_entries_path(user_slug: @holder.slug)
    end

    assert_empty vault.burn_calls, "require_admin must stop a burn before it reaches the chain"
    assert_response :redirect
  end

  # ── The confirmed number is a CEILING ───────────────────────────────────

  test "Burn all destroys only the count the operator was shown, not the live count" do
    # THE OVER-DESTRUCTION REGRESSION. The row renders `unconsumed` from a
    # CACHE-FIRST read (up to 60s stale, and the page never auto-refreshes, so the
    # window is however long the tab stays open), while the controller re-reads
    # the chain LIVE. The Burn-all button used to send no count at all, so the
    # controller fell through to `burnable.length` — the LIVE number — and an
    # operator who accepted "Burn ALL 3" destroyed however many existed by the
    # time the POST landed.
    #
    # Anything can widen that gap between render and click: a LevelUpTokenMintJob
    # sweep, a completed TokenPurchaseJob, another admin's "Mint All Owed".
    # Irreversible, and in the harmful direction.
    shown = [token(ref: "operator:a:1", created_at: 1_000),
             token(ref: "operator:b:1", created_at: 2_000),
             token(ref: "operator:c:1", created_at: 3_000)]
    vault = vault_holding(*shown)

    # The mint that lands between render and click. The button already carries
    # count=3 from the render; the vault now holds 4.
    minted_after_render = token(ref: "operator:late:1", created_at: 9_000)
    vault.tokens_for(@holder.solana_address) << minted_after_render

    Solana::Vault.stub :new, vault do
      post admin_burn_free_entries_path(user_slug: @holder.slug, count: 3)
    end

    assert_equal 3, vault.burn_calls.length,
      "the operator agreed to burn 3; 4 existed by the time the POST landed, and " \
      "only the confirmed number may be destroyed"
    assert_equal 1, vault.list_entry_tokens(@holder.solana_address).count { |t| !t[:consumed] },
      "exactly one token must survive — the one the operator never agreed to burn"

    # WHICH three is deliberately not asserted beyond the count. Newest-first
    # means the late mint IS among them and the oldest survives, so the surviving
    # SET differs from the surviving one the operator pictured. That is
    # acceptable for an action whose whole intent is "zero this balance": the
    # safety property is the ceiling on HOW MANY are destroyed, and a burn can
    # only ever be short, never over.
  end

  test "a stale HIGH count cannot burn more than actually exists" do
    # The mirror case: tokens were SPENT between render and click, so the
    # confirmed number now exceeds reality. The clamp must floor it at what is
    # actually burnable rather than raising or over-reaching.
    vault = vault_holding(token(ref: "operator:a:1", created_at: 1_000),
                          token(ref: "operator:spent:1", created_at: 2_000, consumed: true))

    Solana::Vault.stub :new, vault do
      post admin_burn_free_entries_path(user_slug: @holder.slug, count: 5)
    end

    assert_equal ["operator:a:1"], vault.burn_calls,
      "a count larger than the burnable list must clamp down, not reach past it"
    assert_match(/burned 1 free entry/i, flash[:notice].to_s)
  end

  # ── The property the whole design exists for ────────────────────────────

  test "a burned token still counts as granted, so owed does not re-open" do
    # THE regression this feature is shaped around. `owed` is
    # (seeds / SEEDS_PER_LEVEL) - tokens.length, read off the CHAIN. If a burn
    # removed the account, tokens.length would drop, owed would climb, and the
    # page's own "Mint all" — plus the next level-up sweep — would mint the
    # burned token straight back. The tombstone is what stops that: the account
    # survives, so the count survives.
    tokens = (1..2).map { |i| token(ref: "operator:#{i}:1", created_at: 1_000 * i) }
    vault  = vault_holding(*tokens)
    before = vault.list_entry_tokens(@holder.solana_address).length

    Solana::Vault.stub :new, vault do
      post admin_burn_free_entries_path(user_slug: @holder.slug)
    end

    after = vault.list_entry_tokens(@holder.solana_address)
    assert_equal before, after.length,
      "a burn must not change the on-chain token COUNT — that count is what " \
      "owed and Tokens::LevelUpGrant#missing_levels both derive from"
    assert after.all? { |t| t[:consumed] }, "every burned token reads as consumed"
    assert_equal 0, after.count { |t| !t[:consumed] }, "nothing spendable is left"
  end
end
