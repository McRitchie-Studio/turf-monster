# Central accessor for environment feature flags.
#
# test_scaffolding? gates throwaway, test-only options that must be DISABLED
# before the public production launch:
#   - the $1 "micro" contest tier   (see Contest::FORMATS / Contest.selectable_formats)
#   - the $5 / 3-token entry bundle  (see StripePurchase::PACKS / .available_packs)
#
# Off by default everywhere — including production — unless the operator sets
# ENABLE_TEST_SCAFFOLDING=true. To disable before launch, unset the env var.
# Production BOOTS with it on (since 2026-08-27) so the $1 micro tier can be
# rehearsed on mainnet; the boot logs at ERROR + Sentry rather than raising.
# See config/initializers/test_scaffolding_guard.rb for what that costs.
#
# cdp_ramp? gates the Coinbase CDP Onramp/Offramp integration (buy USDC /
# cash out via the Coinbase-hosted widget) — routes, controllers, and all UI
# entry points. Off by default everywhere; unsetting ENABLE_CDP_RAMP is the
# kill-switch. See docs/CDP_RAMP_INTEGRATION.md §2.
module AppFlags
  # True when test-only scaffolding (micro tier, $5 token bundle) is enabled.
  def self.test_scaffolding?
    ENV["ENABLE_TEST_SCAFFOLDING"].to_s.strip.downcase == "true"
  end

  # True when the Coinbase CDP Onramp/Offramp (buy / cash out USDC) is enabled.
  def self.cdp_ramp?
    ENV["ENABLE_CDP_RAMP"].to_s.strip.downcase == "true"
  end

  # True when the Coinflow entry-token rail is enabled — the hosted-checkout
  # flow (Coinflow pays, then we mint the PACK's quantity, the same on-chain end
  # state as the PayPal token-buy). Gates the buy-page cards (one per pack), the
  # Add Funds hub rail, the /tokens/coinflow_order endpoint, and the
  # /webhooks/coinflow settlement handler. Off by default everywhere; unsetting
  # ENABLE_COINFLOW is the kill-switch. Additive — stacks ALONGSIDE the
  # Coinbase / PayPal / Stripe rails, not a mutually-exclusive provider.
  def self.coinflow?
    ENV["ENABLE_COINFLOW"].to_s.strip.downcase == "true"
  end

  # True when the Aeropay bank-payment entry-token rail is enabled — the "Buy 1
  # entry" pay-by-bank (ACH + RTP) flow (Aeropay pulls from the buyer's linked
  # bank, then we mint exactly 1 entry token, the same on-chain end state as the
  # Coinflow / PayPal token-buy). Gates the buy-page card, the Add Funds hub
  # rail, the /tokens/aeropay_order endpoint, and the /webhooks/aeropay
  # settlement handler. Off by default everywhere; unsetting ENABLE_AEROPAY is
  # the kill-switch. Additive — stacks ALONGSIDE the Coinflow / Coinbase /
  # PayPal / Stripe rails as Turf's INDEPENDENT hedge rail, not a
  # mutually-exclusive provider.
  def self.aeropay?
    ENV["ENABLE_AEROPAY"].to_s.strip.downcase == "true"
  end

  # True for stable QA apps that run Rails in production mode but must still
  # identify themselves as non-production review targets. Delegates to the
  # engine so every QA_ENV reader shares ONE truthiness (the EnvironmentBanner
  # allow-list) — this was the third, stricter vocabulary for the same flag.
  def self.qa_environment?
    Studio.qa_environment?
  end

  # True only on a REAL production deployment: Rails.env is production AND
  # this is not a QA app.
  #
  # The OPSEC-020 kill-switches (faucet, airdrop, add_funds, admin mint) used
  # to ask `Rails.env.production?` directly. A QA Heroku app sets no RAILS_ENV,
  # so the buildpack boots it as production — and there is no
  # config/environments/qa.rb (nor a `qa:` key in database.yml) to switch it
  # to. `Rails.env.production?` therefore read TRUE on QA and disarmed every
  # dev-funding tool there, leaving a devnet QA app with no way to fund a test
  # wallet. QA_ENV is the flag this codebase already uses to tell the two
  # apart (see qa_environment? and the layout's data-app-environment).
  #
  # Guards asking this stay closed on mainnet production, where QA_ENV is
  # never set — and each of them keeps its independent
  # `Solana::Config.devnet?` raise, so production is refused twice over.
  def self.live_production?
    Rails.env.production? && !qa_environment?
  end

  # True when the legal-age attestation checkbox gates account creation
  # (signin page, auth modal, wallet-connect modal). The checkbox itself is
  # the ENGINE partial studio/modals/shared/_age_attestation, which does NOT
  # self-gate — each of those three callsites wraps its render in this flag.
  # Parked OFF for the first contest (operator call, 2026-06-10); set
  # ENABLE_AGE_ATTESTATION=true to restore the full gate. While off the
  # checkbox doesn't render, every client/server gate passes, and —
  # deliberately — new users get NO age_attested_at stamp: we never record
  # an attestation the user wasn't actually shown.
  def self.age_attestation?
    ENV["ENABLE_AGE_ATTESTATION"].to_s.strip.downcase == "true"
  end

  # True when the age gate runs at FIRST CONTEST ENTRY (date-of-birth modal in
  # the hold-to-confirm flow) instead of at signup. The newer, lower-friction
  # model (2026-06-12): the legal-age requirement is tied to the regulated
  # action (entering a paid skill contest), collects a real DOB validated
  # against the user's state minimum age (AgePolicy), stamps age_attested_at +
  # date_of_birth once, and every later entry passes through. SUPERSEDES the
  # signup checkbox (age_attestation?) — run one or the other, not both. Off by
  # default; set ENABLE_AGE_GATE=true.
  def self.age_gate?
    ENV["ENABLE_AGE_GATE"].to_s.strip.downcase == "true"
  end

  # True when a web2 / managed-wallet user with enough USDC can fund a contest
  # entry directly — the server signs the EXISTING on-chain enter_contest (USDC)
  # instruction with the user's custodial keypair (Solana::Vault#enter_contest_with_usdc).
  # This is what lets a USDC contest payout fund the next entry.
  #
  # DEFAULT ON — unlike every other flag here this is an operator KILL-SWITCH,
  # not an opt-in: web2 USDC entry is live unless ENABLE_WEB2_USDC_ENTRY is set
  # to "false", which reverts web2 to TOKEN-ONLY (today's pre-unification
  # behavior). web3 (Phantom) USDC/USDT entry is unaffected either way; USDT is
  # never offered to web2 (payouts are USDC, so managed users won't hold USDT).
  def self.web2_usdc_entry?
    ENV.fetch("ENABLE_WEB2_USDC_ENTRY", "true").to_s.strip.downcase != "false"
  end

  # True when new email / Google accounts are WEB3-ONLY: signup no longer mints
  # a custodial web2 wallet (User#generate_managed_wallet! returns early), and
  # auth success routes the user into the wallet-setup modal to link Phantom
  # instead (WalletSetupPolicy).
  #
  # Operator call for NFL 2026: supporting web2 players carries a legal cost
  # Turf can't absorb this season, so every player onboards pure web3.
  #
  # DEFAULT ON — a KILL-SWITCH, like web2_usdc_entry? above and unlike every
  # opt-in flag between them. It was an opt-in through the build-out, off
  # everywhere, which is what made a freshly signed-up player still land on the
  # web2 Buy an Entry Token modal after the onboarding chain: the wallet step
  # was written, wired and dark. The season it was built for has arrived, so the
  # default now states it — web3-only is the behavior unless
  # ENABLE_WEB3_ONLY_ONBOARDING is set to "false", which reverts the whole
  # season's onboarding to web2 in one env change with no deploy. That
  # revertibility is why the wallet minting is still gated here rather than
  # deleted.
  #
  # EXISTING managed wallets are untouched either way: this gates MINTING at
  # signup, never the rails that serve the wallets already out there.
  def self.web3_only_onboarding?
    ENV.fetch("ENABLE_WEB3_ONLY_ONBOARDING", "true").to_s.strip.downcase != "false"
  end
end
