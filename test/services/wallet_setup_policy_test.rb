require "test_helper"

# WalletSetupPolicy — who has to link a self-custody wallet (web3-only
# onboarding, 2026-08). One rule, shared by both auth-success paths and the
# entry gate, so these cases are the whole contract.
class WalletSetupPolicyTest < ActiveSupport::TestCase
  # Stub standing in for Solana::Vault. Counts calls so the cache-first
  # behaviour is asserted on the RPC itself, not on a proxy for it.
  class StubVault
    attr_reader :calls

    def initialize(usdc:, raises: false)
      @usdc = usdc
      @raises = raises
      @calls = 0
    end

    def fetch_wallet_balances(_address)
      @calls += 1
      raise Solana::Client::RpcError, "simulated flake" if @raises

      { sol: 0.0, usdc: @usdc, usdt: 0.0 }
    end
  end

  # --- the free-entry bypass (operator QA, 2026-09-09) ---
  #
  # A gifted player has the price of admission in hand, so the wallet nudge is
  # asking them to solve a problem they do not have. These are the two shapes
  # that reach the policy, and the second is the one the bug lived in.

  test "a managed user holding an entry token needs no wallet setup" do
    user = managed_user
    user.stub :entry_token_balance, 1 do
      assert_not WalletSetupPolicy.required_for?(user, vault: StubVault.new(usdc: 0.0))
    end
  end

  # THE ONE THAT MATTERS. The verdict is computed ONCE at sign-in, and at that
  # instant a just-claimed gift has NO token yet — the claim is synchronous, the
  # mint is a queued job. A token-only bypass reads false here, arms the modal
  # for the whole session, and reproduces the reported bug exactly.
  test "a claimed gift whose mint is still queued needs no wallet setup" do
    user = managed_user
    gift = EntryGift.create!(recipient_email: user.email, sender: users(:alex))
    gift.update!(claimed_by: user, claimed_at: Time.current)

    user.stub :entry_token_balance, 0 do
      assert_not WalletSetupPolicy.required_for?(user, vault: StubVault.new(usdc: 0.0)),
                 "a gift in flight must not trigger the wallet nudge"
    end
  end

  # THE CONTROL. Same user, same zero balance, NO gift — the nudge still fires.
  # Without this the two tests above pass for a policy that never asks anyone.
  test "a managed user with no entry and no USDC still needs wallet setup" do
    user = managed_user
    user.stub :entry_token_balance, 0 do
      assert WalletSetupPolicy.required_for?(user, vault: StubVault.new(usdc: 0.0))
    end
  end

  # The bypass must not outlive the entry it is based on. A gift that has been
  # MINTED is covered by the token half; once that token is spent, both halves
  # go false and the account is an ordinary empty managed wallet again.
  test "a spent gift restores the wallet nudge" do
    user = managed_user
    gift = EntryGift.create!(recipient_email: user.email, sender: users(:alex))
    gift.update!(claimed_by: user, claimed_at: 1.hour.ago, minted_at: 1.hour.ago,
                 mint_signature: "sig_spent")

    user.stub :entry_token_balance, 0 do # minted, then consumed
      assert WalletSetupPolicy.required_for?(user, vault: StubVault.new(usdc: 0.0)),
             "a spent gift must not buy a permanent bypass"
    end
  end

  # A gift that can NEVER be paid (an admin claimant — OPSEC-044) carries a
  # mint_error, and must not buy a bypass either: there is no entry coming.
  test "an unpayable gift does not bypass the nudge" do
    user = managed_user
    gift = EntryGift.create!(recipient_email: user.email, sender: users(:alex))
    gift.update!(claimed_by: user, claimed_at: Time.current,
                 mint_error: "admin accounts hold no custodial keys")

    user.stub :entry_token_balance, 0 do
      assert WalletSetupPolicy.required_for?(user, vault: StubVault.new(usdc: 0.0))
    end
  end

  # A token read that FAULTS must not grant a bypass — the direction to fail is
  # "ask about the wallet", never "wave an empty account into a contest".
  test "a failed token read falls through rather than bypassing" do
    user = managed_user
    boom = ->(*) { raise "RPC down" }
    user.stub :entry_token_balance, boom do
      assert WalletSetupPolicy.required_for?(user, vault: StubVault.new(usdc: 0.0))
    end
  end

  # Every case below is about what the policy says WHEN THE FEATURE IS ON. The
  # flag-off behaviour is its own contract, asserted at the bottom.
  def setup
    Rails.cache.clear
    ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = "true"
  end

  def teardown
    ENV.delete("ENABLE_WEB3_ONLY_ONBOARDING")
  end

  def managed_user
    user = users(:jordan)
    user.update_columns(web2_solana_address: "Managed#{user.id}", web3_solana_address: nil)
    user
  end

  test "MIN_USDC is one paid entry — pinned to Contest::FORMATS" do
    # The threshold is the operator's rule ("19+ USDC is useable"), and it is
    # only meaningful while a paid entry costs $19. If the entry fee moves, this
    # fails and the policy gets revisited instead of silently drifting.
    paid_fees = Contest::FORMATS.values.map { |f| f[:entry_fee_cents] }.reject(&:zero?).uniq
    assert_includes paid_fees, WalletSetupPolicy::MIN_USDC * 100,
                    "MIN_USDC ($#{WalletSetupPolicy::MIN_USDC}) no longer matches a paid entry fee: #{paid_fees.inspect}"
  end

  test "no user means no setup prompt" do
    assert_not WalletSetupPolicy.required_for?(nil)
  end

  test "a phantom-linked account never needs setup" do
    user = users(:jordan)
    user.update_columns(web3_solana_address: "Phantom#{user.id}")
    vault = StubVault.new(usdc: 0.0)
    assert_not WalletSetupPolicy.required_for?(user, vault: vault)
    assert_equal 0, vault.calls, "a phantom account must be decided from columns alone — no RPC"
  end

  test "an account with no wallet at all needs setup, with no RPC" do
    user = users(:jordan)
    user.update_columns(web2_solana_address: nil, web3_solana_address: nil)
    vault = StubVault.new(usdc: 0.0)
    assert WalletSetupPolicy.required_for?(user, vault: vault)
    assert_equal 0, vault.calls, "no wallet is decidable without a balance read"
  end

  test "a managed wallet holding more than an entry is left alone" do
    user = managed_user
    vault = StubVault.new(usdc: 25.0)
    assert_not WalletSetupPolicy.required_for?(user, vault: vault)
  end

  test "a managed wallet holding exactly the threshold is left alone" do
    # Boundary: the operator's rule is "19+ USDC", so 19.00 passes.
    user = managed_user
    vault = StubVault.new(usdc: 19.0)
    assert_not WalletSetupPolicy.required_for?(user, vault: vault)
  end

  test "a managed wallet a cent short of the threshold needs setup" do
    user = managed_user
    vault = StubVault.new(usdc: 18.99)
    assert WalletSetupPolicy.required_for?(user, vault: vault)
  end

  test "an empty managed wallet needs setup" do
    user = managed_user
    vault = StubVault.new(usdc: 0.0)
    assert WalletSetupPolicy.required_for?(user, vault: vault)
  end

  # The two cases below assert the CACHE behaviour, so they need a cache that
  # actually stores. The test env runs :null_store (every read returns nil), so
  # without this swap they would pass for the wrong reason — the null store
  # makes "cache miss" the only reachable path.
  def with_real_cache
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stub :cache, store do
      yield store
    end
  end

  test "a warm balance cache is used instead of an RPC" do
    with_real_cache do |store|
      user = managed_user
      store.write("usdc_balance:#{user.id}", 42.0)
      vault = StubVault.new(usdc: 0.0)   # would say "needs setup" if consulted
      assert_not WalletSetupPolicy.required_for?(user, vault: vault)
      assert_equal 0, vault.calls, "a warm cache must short-circuit the RPC"
    end
  end

  test "a fresh read warms the cache the navbar reads" do
    with_real_cache do |store|
      user = managed_user
      vault = StubVault.new(usdc: 31.0)
      WalletSetupPolicy.required_for?(user, vault: vault)
      assert_equal 31.0, store.read("usdc_balance:#{user.id}"),
                   "the sign-in fetch should not be thrown away"
    end
  end

  test "an RPC failure resolves to setup-required and does not raise" do
    # Deliberate direction to fail: the modal is dismissible, so a flake costs a
    # funded user one closable card. Failing the other way would wave an EMPTY
    # managed wallet into a flow it can no longer fund.
    user = managed_user
    vault = StubVault.new(usdc: nil, raises: true)
    assert_nothing_raised { WalletSetupPolicy.required_for?(user, vault: vault) }
    assert WalletSetupPolicy.required_for?(user, vault: vault)
  end

  test "a nil usdc reading (no ATA yet) resolves to setup-required" do
    # A brand-new managed wallet has no USDC token account at all.
    user = managed_user
    vault = StubVault.new(usdc: nil)
    assert WalletSetupPolicy.required_for?(user, vault: vault)
  end

  # --- Flag OFF: the whole policy stands down ---------------------------------
  #
  # Not a formality. With web3-only onboarding off, web2 is a SUPPORTED path: a
  # managed user under the threshold is meant to reach a web2 funding rail
  # (entry token / Coinflow / on-ramp), and a "link Phantom" nudge would stand
  # in front of the very flows that fix a low balance — and the entry gate that
  # reads this policy would block them outright. So "flag off ⇒ nothing
  # changes" has to hold for the POLICY, not just for wallet minting.

  # "Off" is now an EXPLICIT "false", not an absent var: the flag became a
  # kill-switch on 2026-08-15, so deleting it turns the policy ON. Setting the
  # value is what these three actually mean.
  test "an empty managed wallet is left alone while the flag is off" do
    ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = "false"
    user = managed_user
    vault = StubVault.new(usdc: 0.0)
    assert_not WalletSetupPolicy.required_for?(user, vault: vault)
    assert_equal 0, vault.calls, "with the feature off the policy shouldn't even read a balance"
  end

  test "a wallet-less account is left alone while the flag is off" do
    # With the flag off, signup mints a wallet, so the only wallet-less accounts
    # are admins (OPSEC-044) — who must not be nagged on every login.
    ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = "false"
    user = users(:jordan)
    user.update_columns(web2_solana_address: nil, web3_solana_address: nil)
    assert_not WalletSetupPolicy.required_for?(user)
  end

  test "an explicit false disables the policy too" do
    ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = "false"
    user = managed_user
    assert_not WalletSetupPolicy.required_for?(user, vault: StubVault.new(usdc: 0.0))
  end
end
