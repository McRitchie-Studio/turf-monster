# frozen_string_literal: true

require "test_helper"

# THE TWO CONTEST CALL SITES MUST DROP **BOTH** NAVBAR BALANCE KEYS.
#
# PR #592 added ApplicationController#invalidate_wallet_balance_cache and put it
# on #finalize and #finalize_bundle. It did not reach the two sites below, which
# still call #invalidate_usdc_cache — the ONE-key drop. This file pins them.
#
# WHY ONE KEY IS WRONG WHEREVER THE PILL IS COMBINED. #display_balance renders
# usdc + usdt SUMMED, and #combined_balance returns nil — the "loading" state
# the client fills via refreshBalance — only when BOTH reads are nil; a nil
# beside a live value counts as ZERO. Both keys are written together on the same
# 60s TTL (see the pair of Rails.cache.write calls in #hydrate_wallet_payload),
# and the USDT write carries `|| 0`, so the twin is warm essentially whenever
# its partner is. A one-key drop therefore never yields "loading". It yields the
# SURVIVING key presented as the whole wallet total.
#
# That is why every assertion here is on the NUMBER the pill would render, not
# on a boolean. A flag-only assertion ("was something invalidated?") passes on
# the broken behaviour, and a zero-valued twin makes the wrong total look
# plausible — so the fixtures below give USDT a NON-ZERO value on purpose.
#
# SCOPE, STATED HONESTLY. Both writes carry `expires_in: 60.seconds`, so the
# wrong total self-heals within a minute. This is an optimisation that closes a
# sub-minute stale window, NOT a correctness guarantee, and nothing here should
# be read as claiming more.
#
# Task: stale-usdt-balance-after-spend.
class ContestsUsdtBalanceCacheTest < ActionDispatch::IntegrationTest
  # A non-zero USDT twin. If the fix ever regresses to the one-key drop, the
  # pill reports exactly this number as the user's whole balance.
  WARM_USDC = 1284.0
  WARM_USDT = 7.0

  setup do
    @user  = users(:sam)   # web3_solana_address fixture -> solana_connected?
    @admin = users(:alex)  # #confirm_onchain_contest is require_admin
    SeasonConfig.set_current!(1)
  end

  # --- helpers -------------------------------------------------------------

  def warm_both(user)
    Rails.cache.write("usdc_balance:#{user.id}", WARM_USDC, expires_in: 60.seconds)
    Rails.cache.write("usdt_balance:#{user.id}", WARM_USDT, expires_in: 60.seconds)
  end

  def balance_keys_for(user)
    [Rails.cache.read("usdc_balance:#{user.id}"), Rails.cache.read("usdt_balance:#{user.id}")]
  end

  # The NUMBER the navbar pill renders for this user, straight off the cache —
  # the same cache-first branch #display_balance takes on any page that does not
  # preload @wallet_balances. nil == the "loading" face.
  def pill_total_for(user)
    ApplicationController.new.tap { |c| c.define_singleton_method(:current_user) { user } }
                             .send(:display_balance)
  end

  def assert_pill_reads_loading(user, spend:)
    assert_equal [nil, nil], balance_keys_for(user),
      "#{spend}: both balance keys must be dropped — dropping one leaves the other warm"
    assert_nil pill_total_for(user),
      "#{spend}: the pill must read LOADING so refreshBalance fills it. It instead renders " \
      "$#{pill_total_for(user).to_f.to_i} — the surviving key served as the whole wallet total."
  end

  def free_contest
    Contest.create!(
      name: "Free Plumbing Contest", slate: slates(:one), contest_type: "standard",
      entry_fee_cents: 0, max_entries: 29, status: :open, starts_at: 2.weeks.from_now
    )
  end

  # --- SITE B: #post_entry_seeds_payload (the USER-FACING entry path) -------
  #
  # Reached by BOTH entry routes: #enter (managed/web2) and #confirm_onchain_entry
  # (phantom-direct). The phantom route is the one that can spend USDT —
  # #prepare_entry maps currency "usdt" to currency_idx 1 / Config::USDT_MINT —
  # so on that route the one-key drop clears the key that did NOT move and keeps
  # the stale pre-spend USDT that DID. Driving #enter here exercises the very
  # same shared line with far less Solana scaffolding.

  test "a confirmed entry drops BOTH balance keys, not just USDC" do
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      log_in_as(@user)
      contest = free_contest
      entry = contest.entries.create!(user: @user, status: :cart)
      %i[m1 m2 m3 m4 m5 m6].each { |m| entry.selections.create!(slate_matchup: slate_matchups(m)) }

      warm_both(@user)
      assert_equal [WARM_USDC, WARM_USDT], balance_keys_for(@user), "precondition: both keys warm"

      post enter_contest_path(contest), headers: { "Accept" => "application/json" }

      assert_response :success
      assert entry.reload.active?, "precondition: the entry must actually have been confirmed"
      assert_pill_reads_loading(@user, spend: "entry")
    end
  end

  # The unit-tier twin of the test above: the shared helper itself, off the
  # route. #confirm_onchain_entry reaches this same method, and it is the route
  # that spends USDT — so pinning the helper covers the USDT path without
  # stubbing the cosign/broadcast/verify chain that route runs first.
  test "post_entry_seeds_payload drops BOTH keys for a solana-connected user" do
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      contest = free_contest
      entry = contest.entries.create!(user: @user, status: :cart)
      warm_both(@user)

      controller = ContestsController.new
      user = @user
      controller.define_singleton_method(:current_user) { user }
      controller.instance_variable_set(:@contest, contest)

      controller.send(:post_entry_seeds_payload, entry,
                      path: "phantom-direct", tx_signature: "FAKE_SIG_usdt_entry",
                      token_consumed: false)

      assert_pill_reads_loading(@user, spend: "USDT entry (phantom-direct)")
    end
  end

  # --- SITE A: #confirm_onchain_contest (admin contest create) -------------
  #
  # NOTE ON WHAT THIS SITE ACTUALLY SPENDS. The ticket filed it as a USDT spend
  # because the action stamps `accepts_usdt: true` and its comment mentions the
  # slot-1 fee. Both are about PRICE, not payment: #onchain_params fills
  # entry_fee_by_currency[1] as a fee SCHEDULE for future entrants, and
  # Vault#create_contest_instruction binds payout_mint to Config::USDC_MINT and
  # the creator's **USDC** ATA. So this transaction moves USDC.
  #
  # It is still defective, for the mirror-image reason: the creator's USDC just
  # moved, the USDC key is dropped, and the warm USDT twin is then rendered as
  # the entire balance. Same corrupted total, opposite currency.
  test "confirm_onchain_contest drops BOTH balance keys once the create tx is verified" do
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      # The creator of an on-chain contest always holds Phantom —
      # #prepare_onchain_contest raises "Phantom wallet required" without it, and
      # it is the creator's USDC ATA the create tx debits. The fixture admin has
      # no wallet, and a wallet-less user takes #display_balance's DEFINITIVE
      # zero branch, where the cache is never consulted and this test could
      # prove nothing. (Base58 excludes 0/O/I/l.)
      @admin.update!(web3_solana_address: "CrEaToRphantomWa11etAddre55ForTe5tsXYZab")
      log_in_as(@admin)
      contest = contests(:one)
      assert_not contest.onchain?, "precondition: the action refuses an already-onchain contest"

      warm_both(@admin)
      assert_equal [WARM_USDC, WARM_USDT], balance_keys_for(@admin), "precondition: both keys warm"

      Solana::Vault.stub :new, FakeVault.new do
        Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
          Solana::TxVerifier.stub :verify!, true do
            post confirm_onchain_contest_contest_path(contest),
                 params: { contest_pda: "cpda-#{contest.slug}", tx_signature: "FAKE_SIG_create" },
                 as: :json
          end
        end
      end

      assert_response :success
      assert_equal true, response.parsed_body["success"], "precondition: the confirm must have SUCCEEDED"
      assert contest.reload.onchain?, "precondition: the contest must have been stamped onchain"
      assert_pill_reads_loading(@admin, spend: "contest create")
    end
  end
end
