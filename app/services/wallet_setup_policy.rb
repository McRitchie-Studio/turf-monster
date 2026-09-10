# Does this account still need to set up a self-custody wallet?
#
# ONE rule, shared by every auth-success path (MagicLinksController#consume,
# OmniauthCallbacksController#create) and by the entry gate, so "who sees the
# wallet-setup modal" is decided in exactly one place.
#
# The rule, in order:
#   1. Phantom already linked  → NO. They are web3; nothing to set up.
#   2. No wallet at all        → YES. The web3-only onboarding case: signup no
#                                longer mints a managed wallet (AppFlags
#                                .web3_only_onboarding?), so this account cannot
#                                transact until it links one.
#   3. Holds a free entry      → NO. A gifted player already has the price of
#      (token, or one on its      admission in hand and needs no funding rail at
#      way)                       all, so a wallet nudge is asking them to solve
#                                a problem they do not have. This is the whole
#                                point of gifting an entry (operator call,
#                                2026-09-09): "the state of the system should
#                                sense the free entry and not gate any web3
#                                guards … my easy way to make the app
#                                approachable for the aunts of the world."
#   4. Managed wallet, funded  → NO. A grandfathered web2 user holding at least
#      (>= MIN_USDC)             one entry's worth of USDC is USEABLE as-is
#                                (operator call): their custodial rails still
#                                work, so do not interrupt them.
#   5. Managed wallet, short   → YES. Web2 top-up rails are going away for the
#                                season; the way forward is Phantom.
#
# The balance read is the only I/O here. It is cache-first (the same navbar
# cache the hydrate endpoints write) and falls back to ONE blocking RPC, which
# is affordable because this runs on sign-in, not on the render path.
class WalletSetupPolicy
  # One paid entry. Every paid tier in Contest::FORMATS is entry_fee_cents
  # 19_00, so 19 USDC is exactly the price of admission — a managed user holding
  # this much can still enter a contest without touching a web2 funding rail.
  # test/services/wallet_setup_policy_test.rb pins this to FORMATS so a change
  # to the entry fee surfaces here instead of silently drifting.
  MIN_USDC = 19

  def initialize(user, vault: nil)
    @user = user
    @vault = vault
  end

  def self.required_for?(user, vault: nil)
    new(user, vault: vault).required?
  end

  def required?
    return false if user.blank?
    # Gate the WHOLE policy on the flag, not just the wallet minting.
    #
    # This is load-bearing, and getting it wrong is worse than it looks: with
    # web3-only onboarding OFF, web2 IS a supported path, and a managed user
    # under the threshold is supposed to reach for a web2 funding rail (entry
    # token, Coinflow, on-ramp) — the exact flows a "link Phantom" nudge would
    # stand in front of. Nudging them there would break web2 entry with the
    # feature switched off, so "flag off ⇒ nothing changes" has to hold here
    # too, not only at signup.
    return false unless AppFlags.web3_only_onboarding?
    return false if user.phantom_wallet?
    return true unless user.managed_wallet?
    return false if holds_free_entry?

    usdc_balance < MIN_USDC
  end

  private

  attr_reader :user

  # Does this account already hold the price of admission, or is it about to?
  #
  # TWO HALVES, AND THE SECOND ONE IS THE LOAD-BEARING ONE. The obvious half is
  # a token already on chain. The half that actually matters is a gift that has
  # been CLAIMED but whose mint is still queued — because the verdict the entry
  # gate reads is written at only two instants: at sign-in
  # (ApplicationController#record_wallet_setup_state!, which stores it in
  # session[:wallet_setup]) and right after a gift claim on the signed-in path
  # (MagicLinksController#link_continue, the same method). A gifted player's
  # verdict is written straight after the claim either way, and the claim is
  # SYNCHRONOUS while EntryGiftMintJob is ASYNC, so when that stored verdict is
  # written the token does not exist yet. (OnboardingFlow also asks this policy
  # live, after the first-name card; by then the mint may have landed, and the
  # token half answers instead.) A token-only check would read false, arm the
  # modal for the whole session, and reproduce the exact bug this closes.
  #
  # Scoped to mints that are still expected — `mint_error` blank — so a gift
  # that can never be paid (an admin claimant, OPSEC-044) does not silently buy
  # a permanent bypass. Once the mint lands, the first half carries it.
  #
  # A SPENT gift falls out of both halves by construction: the token reads
  # consumed, and minted_at is set so the pending half no longer matches. The
  # bypass lasts exactly as long as the free entry does.
  def holds_free_entry?
    return true if entry_token_balance.positive?

    EntryGift.where(claimed_by: user, minted_at: nil, mint_error: nil)
             .where.not(claimed_at: nil)
             .exists?
  end

  # Cache-first, like #usdc_balance and for the same reason — this runs on
  # sign-in, not the render path. Failure returns 0, which falls through to the
  # USDC question rather than granting a bypass: the direction to fail here is
  # "ask about the wallet", never "wave an empty account into a contest".
  def entry_token_balance
    user.entry_token_balance
  rescue StandardError => e
    Rails.logger.warn("[WalletSetupPolicy] token read failed user=#{user.id}: #{e.class}: #{e.message}")
    0
  end

  # Cache-first, then ONE blocking RPC.
  #
  # On an RPC failure we return 0.0 — which resolves to "setup required". That
  # is the deliberate direction to fail: the modal is dismissible, so a flake
  # costs a funded user one closable card, whereas failing the other way would
  # wave an EMPTY managed wallet through into a flow it can no longer fund.
  def usdc_balance
    cached = Rails.cache.read("usdc_balance:#{user.id}")
    return cached.to_f if cached.present?

    balances = (@vault || Solana::Vault.new).fetch_wallet_balances(user.web2_solana_address)
    usdc = balances.is_a?(Hash) ? balances[:usdc] : nil
    # Warm the same key the navbar reads, so the sign-in fetch isn't wasted.
    Rails.cache.write("usdc_balance:#{user.id}", usdc, expires_in: 60.seconds) unless usdc.nil?
    usdc.to_f
  rescue StandardError => e
    Rails.logger.warn("[WalletSetupPolicy] balance read failed user=#{user.id}: #{e.class}: #{e.message}")
    0.0
  end
end
