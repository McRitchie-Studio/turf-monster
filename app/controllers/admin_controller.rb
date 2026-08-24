class AdminController < ApplicationController
  before_action :require_admin, except: [:usdc_balance]

  # Named modal FLOWS — an ordered sequence a real user walks, as opposed to
  # MODAL_VARIANTS below, which is a flat catalogue of individual states.
  #
  # A flow exists because the interesting bug in a multi-step experience is the
  # ORDER, and a catalogue cannot show order: reviewing "first name" and "age
  # gate" as two unrelated tiles tells you nothing about which one a new user
  # meets first, or what happens when they skip. Each step names a variant key
  # from MODAL_VARIANTS, so the two stay in one registry and the gallery can
  # deep-link a step without duplicating its props.
  #
  # These two mirror OnboardingFlow::STEPS exactly — that service decides the
  # order at runtime, this decides how it is PRESENTED, and
  # test/controllers/onboarding_flow_gallery_test.rb pins them to each other so
  # a step added to the chain cannot go unshown here.
  #
  # DEPRECATED AS A DESTINATION (operator direction, 2026-08-21). Modal PRIMITIVE
  # work goes to the engine's living style guide at /admin/style#modals from now
  # on; a modal built there is inherited by every Studio app, one built here is
  # turf's alone. This registry is not deleted yet for a measured reason rather
  # than an unmade decision: 9 of the modal ids below have no card in the engine
  # guide (wallet-setup, wallet-changed, cdp-ramp, buy-entry-token,
  # cosign-rejected, quest-success, unsubscribe-confirm, unsubscribe-goodbye,
  # web3-step-up), so
  # deleting this page today would drop their only review surface instead of
  # tidying a duplicate. Port first, delete second. The page itself carries the
  # same notice at the top, where someone about to build here will actually see
  # it — see app/views/admin/modals.html.erb.
  MODAL_FLOWS = [
    { key: "onboarding",
      label: "Onboarding (after first auth)",
      summary: "What a brand-new account meets the moment it signs in for the first time.",
      steps: [
        { key: "onboarding-first-name", note: "Marketing capture — SKIPPABLE, never blocks the wallet" }
      ] },
    { key: "web3-step-up",
      label: "Web3 step-up (web2 auth by a wallet account)",
      summary: "A self-custody account signed in with email, a magic link or Google, so the session cannot sign " \
               "on-chain. Opens BEFORE the onboarding chain and hands off to it when dismissed. Two states, and " \
               "which one a user meets depends on whether we remember the wallet brand they last signed with.",
      steps: [
        { key: "web3-step-up-remembered", note: "The common case — one click, no picker" },
        { key: "web3-step-up-unknown",    note: "Wallet linked before we recorded brands — falls back to the picker" }
      ] },
    { key: "wallet-setup",
      label: "Wallet setup",
      summary: "Runs straight after onboarding, and again from the entry gate if dismissed. " \
               "Skipped entirely for a web2 user already holding an entry's worth of USDC.",
      steps: [
        { key: "age-verify",   note: "Prompted here now; STILL enforced at contest entry" },
        { key: "wallet-setup", note: "Install → waiting → Installed → connect" }
      ] }
  ].freeze

  # Manifest of every modal partial + interesting internal state, used by
  # the /admin/modals gallery (see views/admin/modals.html.erb). Each
  # variant is rendered in an iframe via #modal_preview. Keep this in
  # sync with app/views/modals/* and the host registrations in
  # layouts/application.html.erb.
  MODAL_VARIANTS = [
    # === Templates ===========================================================
    # Reference implementations new modal work should copy. Each pairs a
    # visual archetype (form / action / status / wizard) with a complete
    # working modal under app/views/modals/templates/. Registered in the
    # modal host gated to !production. The :partial key tells the gallery
    # to render the variant INLINE (no iframe) — the templates are pure
    # local x-data with no props dependency, so they drop in anywhere.
    # Open ↗ still pushes them onto the live host for full interactive
    # testing (backdrop, escape, click-outside).
    { group: "Templates",
      label: "Wizard (Step N of M + nav)", key: "template-wizard",
      modal_id: "template-wizard", file: "[studio-engine] app/views/studio/modals/templates/_wizard.html.erb",
      partial: "studio/modals/templates/wizard",
      props: {} },
    { group: "Templates",
      label: "Success (large title — celebration)", key: "template-success",
      modal_id: "template-success", file: "[studio-engine] app/views/studio/modals/templates/_success.html.erb",
      partial: "studio/modals/templates/success",
      props: {} },
    { group: "Templates",
      label: "Status (small title — in-flight)", key: "template-status",
      modal_id: "template-status", file: "[studio-engine] app/views/studio/modals/templates/_status.html.erb",
      partial: "studio/modals/templates/status",
      props: {} },
    { group: "Templates",
      label: "Action (icon + question + dual CTA)", key: "template-action",
      modal_id: "template-action", file: "[studio-engine] app/views/studio/modals/templates/_action.html.erb",
      partial: "studio/modals/templates/action",
      props: {} },
    { group: "Templates",
      label: "Form (title + body + CTA)", key: "template-form",
      modal_id: "template-form", file: "[studio-engine] app/views/studio/modals/templates/_form.html.erb",
      partial: "studio/modals/templates/form",
      props: {} },

    { group: "Auth — credentials",
      label: "Credentials (Google / wallet / magic link)", key: "auth-credentials",
      modal_id: "auth", file: "app/views/modals/_auth.html.erb",
      props: { mode: "signup", step: "credentials" } },
    { group: "Auth — credentials",
      label: "Credentials (sending magic link)", key: "auth-credentials-sending",
      # submitting: 'magic-link' drives the Email Link button's .cta-spinner;
      # Google/Solana spin the same way with submitting 'google'/'wallet'.
      modal_id: "auth", file: "app/views/modals/_auth.html.erb",
      props: { mode: "signup", step: "credentials", submitting: "magic-link" } },
    { group: "Auth — credentials",
      label: "Magic link sent", key: "auth-magic-link-sent",
      modal_id: "auth", file: "app/views/modals/_auth.html.erb",
      props: { step: "magic-link-sent", sentEmail: "you@example.com" } },
    { group: "Auth — credentials",
      label: "Magic link resent", key: "auth-magic-link-resent",
      modal_id: "auth", file: "app/views/modals/_auth.html.erb",
      props: { step: "magic-link-resent", sentEmail: "you@example.com" } },
    { group: "Web3",
      label: "Connect Wallet (picker)", key: "wallet-connect",
      modal_id: "wallet-connect", file: "app/views/modals/_wallet_connect.html.erb",
      props: {} },
    { group: "Web3",
      label: "Wallet changed (session handoff)", key: "wallet-changed",
      modal_id: "wallet-changed", file: "app/views/modals/_wallet_changed.html.erb",
      props: { oldAddress: "7xKpWm2DbYp9ExampleOldAddressJZ2Q",
               newAddress: "4nQvR8Lt5ExampleNewAddress9AaF",
               providerLabel: "Phantom", dismissible: false } },
    # Web3-only onboarding (AppFlags.web3_only_onboarding?) — the post-auth
    # "Set up your wallet" step. In the gallery the Phantom row renders in its
    # INSTALL state unless the previewing browser actually has Phantom, which is
    # the state a brand-new player sees.
    # === Web3 step-up ========================================================
    # Web3StepUpPolicy's card: the account holds a self-custody wallet, the
    # SESSION was established by a web2 credential. The two variants are the two
    # halves of that policy's provider memory — remembered (one click) and not
    # (the picker). Both are worth eyeballing because the second is what every
    # account linked before the web3_wallet_provider column existed will see.
    { group: "Web3",
      label: "Step-up (remembered wallet — one click)", key: "web3-step-up-remembered",
      modal_id: "web3-step-up", file: "app/views/modals/_web3_step_up.html.erb",
      props: { provider: "phantom", providerLabel: "Phantom", walletHint: "7xKp…JZ2Q" } },
    { group: "Web3",
      label: "Step-up (no remembered wallet — picker)", key: "web3-step-up-unknown",
      modal_id: "web3-step-up", file: "app/views/modals/_web3_step_up.html.erb",
      props: {} },
    { group: "Web3",
      label: "Set up your wallet (post-auth)", key: "wallet-setup",
      modal_id: "wallet-setup", file: "app/views/modals/_wallet_setup.html.erb",
      props: {} },
    # === Onboarding chain ====================================================
    # The single card of the `onboarding` modal, plus the age gate that follows.
    # Presented as ordered flows by MODAL_FLOWS above; catalogued here as
    # individual states so each can be opened and eyeballed on its own.
    # (A "Welcome (username)" variant sat above this one until 2026-08-15, when
    # the welcome step was retired from the chain.)
    { group: "Onboarding",
      label: "First name (skippable)", key: "onboarding-first-name",
      modal_id: "onboarding", file: "app/views/modals/_onboarding.html.erb",
      props: {} },
    # The DOB gate. Prompted as the first step of Wallet setup since 2026-08-12,
    # and STILL the enforcement point at contest entry — same modal, two callers.
    { group: "Onboarding",
      label: "Age gate (DOB)", key: "age-verify",
      modal_id: "age-verify", file: "app/views/modals/_age_verify.html.erb",
      props: {} },
    { group: "Web3",
      label: "Success (Entry Confirmed)", key: "onchain-success",
      modal_id: "onchain-tx", file: "app/views/modals/blocks/_entry_confirmed.html.erb",
      # lobbyUrl: '#' so the success card's 5s auto-redirect is a
      # harmless hash-change instead of navigating the iframe away.
      props: { state: "success",
               txSignature: "5KJp2N6abc123demoTxSignatureForPreview7xYz8wQrSt",
               lobbyUrl: "#", seedsEarned: 13, seedsTotal: 78 } },
    { group: "Web3",
      label: "Success — level up (Free Entry)", key: "onchain-success-levelup",
      modal_id: "onchain-tx", file: "app/views/modals/blocks/_entry_confirmed.html.erb",
      props: { state: "success",
               txSignature: "5KJp2N6abc123demoTxSignatureForPreview7xYz8wQrSt",
               lobbyUrl: "#", seedsEarned: 70, seedsTotal: 130 } },

    { group: "Auth — token purchase sub-flow",
      label: "Picker", key: "auth-tokens-picker",
      modal_id: "auth", file: "app/views/modals/auth/_tokens.html.erb",
      props: { mode: "signup", step: "tokens-picker" } },
    { group: "Auth — token purchase sub-flow",
      label: "Waiting (Stripe tab open)", key: "auth-tokens-waiting",
      modal_id: "auth", file: "app/views/modals/auth/_tokens.html.erb",
      # lastPackId pre-set so the Re-open Checkout CTA renders enabled
      # in the preview (in the real flow, the picker click sets this).
      props: { step: "tokens-waiting", lastPackId: "single" } },
    { group: "Auth — token purchase sub-flow",
      label: "Confirming (polling mint)", key: "auth-tokens-confirming",
      modal_id: "auth", file: "app/views/modals/auth/_tokens.html.erb",
      props: { step: "tokens-confirming" } },
    { group: "Auth — token purchase sub-flow",
      label: "Minted (Hold to Confirm)", key: "auth-tokens-minted",
      modal_id: "auth", file: "app/views/modals/auth/_tokens.html.erb",
      props: { step: "tokens-minted", mintedCount: 1, mintedBalance: 1 } },
    { group: "Auth — token purchase sub-flow",
      label: "Minted (3 tokens, plural)", key: "auth-tokens-minted-3",
      modal_id: "auth", file: "app/views/modals/auth/_tokens.html.erb",
      props: { step: "tokens-minted", mintedCount: 3, mintedBalance: 3 } },
    { group: "Auth — token purchase sub-flow",
      label: "Error (poll timed out)", key: "auth-tokens-error",
      modal_id: "auth", file: "app/views/modals/auth/_tokens.html.erb",
      props: { step: "tokens-error",
               errorText: "Your purchase is taking longer than expected. Refresh to try again." } },

    { group: "Web3",
      label: "Picker (insufficient USDC/USDT)", key: "wallet-deposit-picker",
      modal_id: "wallet-deposit", file: "app/views/modals/_wallet_deposit.html.erb",
      props: { neededCents: 1900, usdcCents: 300, usdtCents: 0 } },

    # The web2 / managed funds modal at the entry blocker — two stacked
    # entry-token rails (Coinflow buy-1 on top, the Stripe pack picker below).
    # Its web3 counterpart at the same wall is wallet-topup above.
    { group: "Funding",
      label: "Buy an Entry Token (web2 — Coinflow + Stripe)", key: "buy-entry-token",
      modal_id: "buy-entry-token", file: "app/views/modals/_buy_entry_token.html.erb",
      props: {} },

    # === CDP ramp (Coinbase buy / cash-out) ================================
    # One modal id ('cdp-ramp'), step machine on props.step + props.flow.
    # The send-step variants use demoCountdownMinutes — cdpRampFlow's
    # gallery affordance that synthesizes a live deadlineAt at mount
    # (MODAL_VARIANTS is a boot-time constant, so it can't carry one).
    { group: "CDP ramp (Coinbase)",
      label: "Buy — preflight (fees + Coinbase login)", key: "cdp-buy-preflight",
      modal_id: "cdp-ramp", file: "app/views/modals/_cdp_ramp.html.erb",
      props: { flow: "buy", step: "preflight" } },
    { group: "CDP ramp (Coinbase)",
      label: "Sell — preflight (account + 30-min window)", key: "cdp-sell-preflight",
      modal_id: "cdp-ramp", file: "app/views/modals/_cdp_ramp.html.erb",
      props: { flow: "sell", step: "preflight" } },
    { group: "CDP ramp (Coinbase)",
      label: "Opening (minting session)", key: "cdp-opening",
      modal_id: "cdp-ramp", file: "app/views/modals/_cdp_ramp.html.erb",
      props: { flow: "buy", step: "opening" } },
    { group: "CDP ramp (Coinbase)",
      label: "Buy — waiting (Coinbase tab open)", key: "cdp-buy-waiting",
      modal_id: "cdp-ramp", file: "app/views/modals/_cdp_ramp.html.erb",
      props: { flow: "buy", step: "waiting", coinbaseUrl: "#" } },
    { group: "CDP ramp (Coinbase)",
      label: "Sell — awaiting CDP (tab open)", key: "cdp-sell-awaiting",
      modal_id: "cdp-ramp", file: "app/views/modals/_cdp_ramp.html.erb",
      props: { flow: "sell", step: "awaiting-cdp", coinbaseUrl: "#" } },
    { group: "CDP ramp (Coinbase)",
      label: "Sell — send (managed, countdown)", key: "cdp-send-managed",
      modal_id: "cdp-ramp", file: "app/views/modals/_cdp_ramp.html.erb",
      props: { flow: "sell", step: "send", walletMode: "web2",
               sellAmount: "25.00", sellCurrency: "USDC",
               demoCountdownMinutes: 27 } },
    { group: "CDP ramp (Coinbase)",
      label: "Sell — send (Phantom, countdown)", key: "cdp-send-phantom",
      modal_id: "cdp-ramp", file: "app/views/modals/_cdp_ramp.html.erb",
      props: { flow: "sell", step: "send", walletMode: "web3",
               sellAmount: "25.00", sellCurrency: "USDC",
               demoCountdownMinutes: 12 } },
    { group: "CDP ramp (Coinbase)",
      label: "Sell — send (window expired)", key: "cdp-send-expired",
      modal_id: "cdp-ramp", file: "app/views/modals/_cdp_ramp.html.erb",
      props: { flow: "sell", step: "send", walletMode: "web2",
               sellAmount: "25.00", sellCurrency: "USDC",
               demoCountdownMinutes: 0 } },
    { group: "CDP ramp (Coinbase)",
      label: "Sell — settling", key: "cdp-settling",
      modal_id: "cdp-ramp", file: "app/views/modals/_cdp_ramp.html.erb",
      props: { flow: "sell", step: "settling" } },
    { group: "CDP ramp (Coinbase)",
      label: "Buy — done", key: "cdp-buy-done",
      modal_id: "cdp-ramp", file: "app/views/modals/_cdp_ramp.html.erb",
      props: { flow: "buy", step: "done" } },
    { group: "CDP ramp (Coinbase)",
      label: "Sell — done", key: "cdp-sell-done",
      modal_id: "cdp-ramp", file: "app/views/modals/_cdp_ramp.html.erb",
      props: { flow: "sell", step: "done" } },
    { group: "CDP ramp (Coinbase)",
      label: "Sell — failed (late-send copy)", key: "cdp-sell-failed",
      modal_id: "cdp-ramp", file: "app/views/modals/_cdp_ramp.html.erb",
      props: { flow: "sell", step: "failed" } },
    { group: "CDP ramp (Coinbase)",
      label: "Error (session mint failed)", key: "cdp-error",
      modal_id: "cdp-ramp", file: "app/views/modals/_cdp_ramp.html.erb",
      props: { flow: "buy", step: "error",
               errorText: "Couldn't start a Coinbase session. Please try again." } },

    { group: "Auth — redirect",
      label: "Geo restricted (redirect countdown)", key: "auth-redirect",
      modal_id: "auth", file: "app/views/modals/_auth.html.erb",
      # The auth modal's generic countdown-redirect step. Its ONLY production
      # caller is the geo-restriction path (showRedirectModal in
      # contests/_turf_totals_board.html.erb) — so the sample mirrors that.
      # url: nil — cta_redirect drains the bar but skips the actual
      # window.location at timer-end, so the gallery preview stays put.
      props: { step: "redirect", icon: "📍", title: "Location Restricted",
               message: "Contest entries are not available in your state.",
               url: nil, cta: "OK" } },

    { group: "Web3",
      label: "Processing", key: "onchain-processing",
      modal_id: "onchain-tx", file: "app/views/modals/_onchain_tx.html.erb",
      props: { state: "processing", title: "Confirming entry",
               message: "Waiting for Phantom signature…" } },
    { group: "Web3",
      label: "Error (no recovery)", key: "onchain-error",
      modal_id: "onchain-tx", file: "app/views/modals/_onchain_tx.html.erb",
      props: { state: "error", title: "Entry failed",
               errorMessage: "Insufficient SOL to pay network fee." } },
    { group: "Web3",
      label: "Error + Phantom recovery", key: "onchain-error-recovery",
      modal_id: "onchain-tx", file: "app/views/modals/_onchain_tx.html.erb",
      props: { state: "error", title: "Insufficient USDC",
               errorMessage: "You need $19 USDC to enter this contest.",
               recoveryLabel: "Mint $500 Test USDC", recoveryPhantom: false } },
    { group: "Web3",
      # Audit C1 — server refused to co-sign a confirm_onchain_entry tx that
      # didn't match the prepared entry (422, code 'tx_rejected'). Static copy,
      # no props — opens via the shared host registration in studio/modals/_host.
      label: "Cosign rejected (tx mismatch)", key: "cosign-rejected",
      modal_id: "cosign-rejected", file: "app/views/modals/_cosign_rejected.html.erb",
      props: {} },

    { group: "Profile",
      label: "Change username", key: "username",
      # loadable → the gallery shows a "Load" button (next to Open) that opens
      # this modal with previewLoading:true. The rename now adopts the engine
      # leveling-activity primitive (studio/modals/blocks/_change_username), which
      # has no synthetic saving state, so previewLoading is ignored here — Load
      # opens the same view as Open. Kept loadable so the gallery convention stays
      # uniform across profile modals.
      modal_id: "username", file: "app/views/modals/_username.html.erb",
      loadable: true, props: {} },
    { group: "Profile",
      label: "Crop Photo (upload — empty state)", key: "crop-photo-upload",
      # No imageUrl → the modal IS the picker: drop / click to upload. This is
      # the first state of the avatar + contest-banner upload, before a file
      # is chosen. See studio-engine _crop_photo's `x-if="!imageUrl"` branch.
      modal_id: "crop-photo", file: "studio/modals/_crop_photo.html.erb",
      props: {} },
    { group: "Profile",
      label: "Crop Photo (with image — crop state)", key: "crop-photo",
      # imageUrl set → crop view. Avatar cropper ships from studio-engine
      # (studio/modals/_crop_photo, v0.4.12; components/_avatar_cropper v0.4.13).
      modal_id: "crop-photo", file: "studio/modals/_crop_photo.html.erb",
      props: { imageUrl: "/logo.png" } },

    # === Quest / Newsletter (feat/quest-mailing-list) ====================
    # The quest-success + newsletter join + unsubscribe modal chain. All gate
    # on current_user in the host; quest-success reads display_seeds_data
    # (server) for its bar, so the gallery preview shows the viewing admin's seeds.
    { group: "Quest / Newsletter",
      label: "Quest success (+25 + subscribe CTA)", key: "quest-success",
      modal_id: "quest-success", file: "app/views/modals/_quest_success.html.erb",
      props: { seeds_earned: 25, seeds_total: 75, seeds_level: 1 } },
    { group: "Quest / Newsletter",
      label: "Free entry earned (100 seeds / level up)", key: "free-entry-earned",
      modal_id: "free-entry-earned", file: "[studio-engine] app/views/studio/modals/blocks/_free_entry_earned.html.erb",
      props: {} },
    { group: "Quest / Newsletter",
      label: "Newsletter subscribe (consent-gated)", key: "newsletter-subscribe",
      modal_id: "newsletter-subscribe", file: "app/views/modals/_newsletter_subscribe.html.erb",
      props: {} },
    { group: "Quest / Newsletter",
      label: "Newsletter success (+25 — you're in)", key: "newsletter-success",
      modal_id: "newsletter-success", file: "app/views/modals/_newsletter_success.html.erb",
      props: {} },
    { group: "Quest / Newsletter",
      label: "Unsubscribe — are you sure?", key: "unsubscribe-confirm",
      modal_id: "unsubscribe-confirm", file: "app/views/modals/_unsubscribe_confirm.html.erb",
      props: {} },
    { group: "Quest / Newsletter",
      label: "Unsubscribe — see you later", key: "unsubscribe-goodbye",
      modal_id: "unsubscribe-goodbye", file: "app/views/modals/_unsubscribe_goodbye.html.erb",
      props: {} }
  ].freeze

  def navbar
  end

  def level_badges
  end

  def modals
    @variants = MODAL_VARIANTS
    # Resolve each flow's steps to their full variant records once, here, so the
    # view never has to look a key up (and a typo'd key fails loudly in the
    # gallery test instead of rendering a blank step).
    @flows = MODAL_FLOWS.map do |flow|
      flow.merge(steps: flow[:steps].map { |s| s.merge(variant: MODAL_VARIANTS.find { |v| v[:key] == s[:key] }) })
    end
  end

  def modal_preview
    @modal_id    = params[:modal_id].to_s
    @modal_props = params[:props].present? ? (JSON.parse(params[:props]) rescue {}) : {}
    render layout: "modal_preview"
  end

  # Legacy preview route from when the avatar cropper had its own
  # bespoke z-[110] overlay. Now that the cropper goes through the
  # shared modal host, this route is unused — keep it pointing at the
  # same minimal layout for back-compat with any bookmarked URL.
  def modal_preview_crop
    render layout: "modal_preview"
  end

  def hub
    @active_slate   = Slate.joins(:slate_matchups).distinct.order(created_at: :desc).first
    @latest_contest = Contest.order(created_at: :desc).first
  end

  # Read-only navbar-hydrate endpoint (NOT admin-gated — see the
  # `except: [:usdc_balance]` on require_admin). The client calls this on page
  # load and after on-chain successes to fill the navbar that now renders
  # cache-first (display_balance / display_seeds_data read Rails.cache only).
  #
  # One round-trip hydrates everything: USDC + USDT balances + seeds payload.
  # It fetches fresh (blocking is fine — runs after first paint), WARMS the
  # navbar caches (usdc/usdt/seeds), and returns them. `{ balance: }` is kept
  # for back-compat (refreshBalance reads data.balance). current_user only.
  def usdc_balance
    return render json: { error: "Not logged in" }, status: :unauthorized unless logged_in?
    return render json: { balance: 0, usdc: 0, usdt: 0, seeds: nil } unless current_user.solana_connected?

    hydrate = fetch_navbar_hydrate(current_user)
    seeds   = hydrate[:seeds]

    render json: {
      # Combined USDC + USDT (the navbar pill shows total spendable dollars —
      # see display_balance). null when BOTH reads flaked, so the client
      # leaves the prior pill value instead of painting a false $0.
      balance:     combined_balance(hydrate[:usdc], hydrate[:usdt]),
      # Per-currency values — feed $store.session.usdcCents/usdtCents and the
      # /account data-wallet-tile spans. null = unknown (RPC flake), the
      # client null-guards each field.
      usdc:        hydrate[:usdc],
      usdt:        hydrate[:usdt],
      # Entry-token count — same fetch that warms the navbar cache. Feeds the
      # /account data-wallet-tile="tokens" span via updateWalletTiles; null on
      # an RPC flake leaves the prior value. (This endpoint's refreshBalance
      # caller does not repaint the 🎟️ badge itself — page-load hydrate goes
      # through refreshSession — but returning it keeps the two endpoints
      # symmetric and warms the same cache.)
      tokens:      hydrate[:entry_token_count],
      seeds:       seeds,
      level:       (User.level_for(seeds) if seeds),
      toward_next: (User.seeds_toward_next_level(seeds) if seeds),
      progress:    (User.seeds_progress_percent(seeds) if seeds),
      seeds_to_next: (User::SEEDS_PER_LEVEL - User.seeds_toward_next_level(seeds) if seeds)
    }
  rescue => e
    Rails.logger.warn("[usdc_balance] hydrate failed: #{e.message}")
    render json: { balance: 0, usdc: 0, usdt: 0, seeds: nil }
  end

  def mint_usdc
    rescue_and_log(target: current_user) do
      raise "Admin mint is production-disabled" if AppFlags.live_production?  # OPSEC-020
      raise "Mint only available on Devnet" unless Solana::Config.devnet?

      vault = Solana::Vault.new
      admin = Solana::Keypair.admin

      vault.ensure_ata(admin.to_base58, mint: Solana::Config::USDC_MINT)
      amount = Solana::Config.dollars_to_lamports(500)
      result = vault.mint_spl(amount, mint: Solana::Config::USDC_MINT)

      invalidate_usdc_cache
      redirect_back fallback_location: root_path, notice: "Minted $500.00 USDC. TX: #{result[:signature]}"
    end
  rescue StandardError => e
    redirect_back fallback_location: root_path, alert: "Mint failed: #{e.message}"
  end
end
