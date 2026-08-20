require "sidekiq/web"

# Back-to-app link in Sidekiq header
Sidekiq::Web.app_url = "/"

# Admin-only session guard — redirects non-admins to login
class SidekiqAdminMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    session = env["rack.session"] || {}
    user_id = session[Studio.session_key.to_s] || session[Studio.session_key]
    user = user_id && User.find_by(id: user_id)
    # OPSEC-045 (Lazarus audit #17): also require the session's token to match
    # the user's current session_token — so a rotated/revoked session (after the
    # email-change flow or a forced re-login) loses Sidekiq Web access too.
    # admin? alone left /admin/jobs reachable by a stale stolen cookie.
    session_token = session["session_token"] || session[:session_token]

    if user&.admin? && session_token.present? && session_token == user.session_token
      @app.call(env)
    else
      body = <<~HTML
        <!DOCTYPE html>
        <html>
        <head><title>Not Found</title></head>
        <body style="background:#1A1535; color:#f8fafc; font-family:system-ui,sans-serif; display:flex; align-items:center; justify-content:center; min-height:100vh; margin:0;">
          <div style="text-align:center;">
            <p style="font-size:4rem; margin:0;">&#129300;</p>
            <h1 style="font-size:1.5rem; margin:1rem 0 0.5rem;">You look lost</h1>
            <p style="color:#94a3b8; margin-bottom:1.5rem;">There's nothing to see here.</p>
            <a href="/" style="background:#4BAF50; color:#fff; padding:0.5rem 1.5rem; border-radius:0.5rem; text-decoration:none; font-weight:bold;">Take me home</a>
          </div>
        </body>
        </html>
      HTML
      [404, { "Content-Type" => "text/html" }, [body]]
    end
  end
end

Sidekiq::Web.use SidekiqAdminMiddleware

Rails.application.routes.draw do
  mount Sidekiq::Web => "/admin/jobs"

  get "up" => "rails/health#show", as: :rails_health_check

  # The hidden frame the wallet-setup modal loads while it waits for Phantom.
  # A browser extension is injected into documents loaded AFTER it is installed,
  # so a fresh load of THIS page is how an already-open tab finds a Phantom that
  # was not there when the tab opened — without reloading what the user is
  # looking at. See WalletProbeController for the full why.
  get "wallet_probe" => "wallet_probe#show", as: :wallet_probe
  root "contests#world_cup"

  # Prelaunch audit M14 (2026-05-24): dev-only tools — not drawn in production
  # so they don't leak surface area on the public-mainnet app. Drawn in dev +
  # test (so existing template URL helpers continue resolving in the test env).
  unless Rails.env.production?
    get  "toast_test",       to: "toast_test#index"
    post "toast_test/flash", to: "toast_test#trigger_flash"
    get  "seeds_lab",        to: "seeds_lab#index", as: :seeds_lab
  end

  get "turf-totals-v1", to: "pages#turf_totals_v1", as: :turf_totals_v1
  get "terms",          to: "pages#terms",          as: :terms

  # Site-legitimacy / trust pages. A real Privacy Policy, Terms of Service, and
  # About/Contact page are signals wallet scanners (Phantom / Blowfish) and link
  # unfurlers look for when deciding whether a new domain is a legitimate
  # consumer product vs a throwaway drain site. Linked from the global footer.
  get "privacy", to: "pages#privacy", as: :privacy
  get "about",   to: "pages#about",   as: :about
  get "contact", to: "pages#contact", as: :contact

  # Underwriting compliance pages (2026-06): responsible-gaming resources +
  # the published state-eligibility list (rendered live from Studio::GeoSetting
  # so it can never drift from the IP-geolocation enforcement). Linked from the
  # global footer next to the legal links.
  get "responsible-gaming", to: "pages#responsible_gaming", as: :responsible_gaming
  get "state-eligibility",  to: "pages#state_eligibility",  as: :state_eligibility

  # Web3 onboarding guide (NFL 2026): with web2 entry off, this is the public
  # walkthrough early adopters follow — install Phantom, secure the recovery
  # phrase, buy $25 of USDC through MoonPay inside Phantom, enter a contest.
  get "getting-started", to: "pages#getting_started", as: :getting_started

  # Public proof-of-reserves — reads on-chain Contest PDAs and the shared
  # vault USDC token account from the browser via Solana RPC, then displays
  # them next to the Rails-reported figures.
  get "proof-of-reserves", to: "proof_of_reserves#show", as: :proof_of_reserves

  # Public contract transparency page — infographic of the turf-vault
  # smart contract (binary size, rent cost, per-instruction breakdown,
  # auth model). Operators see expanded admin-only sections + an
  # operational playbook when current_user&.admin?.
  get "contract", to: "contract#show", as: :contract

  # Public Transparency hub — one page that links to every trust / legitimacy /
  # help page (on-chain program, proof of reserves, source code, legal, help).
  # Handed to reviewers as a single URL; cited in the Phantom / Blowfish appeal.
  get "transparency", to: "transparency#show", as: :transparency

  # Public faucet page
  get  "faucet", to: "faucet#show", as: :faucet
  post "faucet", to: "faucet#claim"

  # Help center
  get "help",              to: "help#index",       as: :help
  get "help/how-to-play",  to: "help#how_to_play", as: :help_how_to_play
  get "help/phantom",      to: "help#phantom",     as: :help_phantom
  get "help/glossary",     to: "help#glossary",    as: :help_glossary

  # Landing pages — public funnel pages (admin-managed via Admin::LandingPagesController).
  # Live at /lp/:slug now that /l/<token> is the unified Studio::Link entry point
  # (below). Old /l/:slug links 301 to /lp via Studio::LinksController#show fallback.
  get "lp/:slug", to: "landing_pages#show", as: :landing_page

  # Phantom deep link callback — must be before Studio.routes to avoid
  # matching OmniAuth's /auth/:provider/callback wildcard
  get  "auth/phantom/callback", to: "solana_sessions#phantom_callback"

  # Unified auth — login + signup are one create-or-login flow, so they share a
  # single canonical page at /signin (sessions#new). The legacy /login + /signup
  # GETs 301 here, preserving the query string so ?reference= funnel attribution
  # (ApplicationController#capture_reference) and ?email= prefill survive the hop.
  # These are defined BEFORE Studio.routes so they win GET recognition; the engine
  # still draws /login + /signup below, keeping the login_path/signup_path helpers
  # and the POST /login + POST /signup actions intact. as: nil avoids a name clash
  # with those engine-named routes.
  get "signin", to: "sessions#new", as: :signin
  signin_redirect = ->(_params, req) { req.query_string.present? ? "/signin?#{req.query_string}" : "/signin" }
  get "login",  to: redirect(&signin_redirect), as: nil
  get "signup", to: redirect(&signin_redirect), as: nil

  Studio.routes(self)

  # Unified Studio::Link entry point — /l/<token> for BOTH magic-link sign-in and
  # referral invites (landing pages moved to /lp). Handled by this app's OWN
  # Studio::LinksController, NOT the engine's: magic-link consume goes through
  # turf's GATED sign_up_new (legal-age attestation, contest landing), and
  # referral is GET-only (attribution cookie + redirect). draw_link_routes stays
  # false so the engine doesn't also draw its gateless /l consume.
  get  "l/:token", to: "studio/links#show",    as: :link,         constraints: { token: %r{[^/]+} }
  post "l/:token", to: "studio/links#consume", as: :link_consume, constraints: { token: %r{[^/]+} }
  # Back-compat: invite links already shared as /i/<token> 301 to the new /l.
  get  "i/:token", to: redirect("/l/%{token}"), constraints: { token: %r{[^/]+} }

  # Solana wallet auth
  get  "auth/solana/nonce",  to: "solana_sessions#nonce"
  post "auth/solana/verify", to: "solana_sessions#verify"

  # Wallet-login landing for a Google sign-in that collided with a wallet
  # account — see OmniauthCallbacksController#create.
  get  "login/wallet",       to: "solana_sessions#link_wallet", as: :link_wallet

  # Google OAuth popup entrypoint — sets a popup-mode session flag, then
  # hands off to OmniAuth. The callback renders a window-closer page.
  get "auth/google_popup", to: "omniauth_callbacks#popup"

  # Email verification (OPSEC-005). Tokens are message_verifier blobs that
  # contain dots; constraints: { token: /.+/ } stops Rails from interpreting
  # them as URL format extensions.
  get  "email_verification/new",       to: "email_verifications#new",    as: :email_verifications_new
  post "email_verification",           to: "email_verifications#create", as: :email_verifications
  get  "email_verification/:token",    to: "email_verifications#verify", as: :email_verifications_verify,
       constraints: { token: %r{[^/]+} }, format: false

  # Unified create-or-login magic link. Same token-with-dots constraint as
  # email_verification above.
  #
  #   POST /magic_link         — request a link (email [, contest, picks, return_to])
  #   GET  /magic_link/:token  — "Confirm sign-in" interstitial (does NOT consume)
  #   POST /magic_link/:token  — consume the token + sign in / create the account
  #
  # The GET is deliberately INERT: email link-scanners / Gmail-image-proxies /
  # corporate SafeLinks pre-fetch the emailed URL, and if the GET consumed the
  # single-use token the human's first real click would already see "link used".
  # So the GET only renders a one-button confirmation page; the human's click
  # POSTs back here and THAT burns the token. A scanner's GET does nothing.
  post "magic_link",        to: "magic_links#create",  as: :magic_link_request
  get  "magic_link/:token", to: "magic_links#confirm", as: :magic_link,
       constraints: { token: %r{[^/]+} }, format: false
  post "magic_link/:token", to: "magic_links#consume", as: :magic_link_consume,
       constraints: { token: %r{[^/]+} }, format: false

  # Account management
  resource :account, only: [:show, :update] do
    get :complete_profile
    post :save_profile
    post :link_solana
    post :unlink_google
    patch :set_inviter
    post :update_username   # on-chain username edit (custodial server-signs / Phantom co-signs)
    post :confirm_username  # Phantom: confirm the co-signed set_username TX
    get :session_state, defaults: { format: :json } # visibilitychange rehydrate
    get :session_refresh, defaults: { format: :json } # on-chain state for refreshSession()
    # OPSEC-007: removed `patch :update_level` — client-supplied seeds_total.
    post :initiate_wallet_export   # task #11 Stage 1: mint signed token + email magic link
  end

  # Out-of-band email-change confirmation (Lazarus audit #4). Token is a signed
  # payload from AccountsController#update; same token-with-dots constraint as
  # the wallet-export route below so embedded periods aren't treated as a URL
  # format extension. Authed by the token, not the session. The GET only renders
  # an interstitial — the actual swap is the CSRF-protected POST, so a link
  # prefetcher / mail scanner (which issue GETs) can't auto-apply the change.
  get  "account/email/confirm/:token", to: "accounts#confirm_email_change", as: :confirm_email_change,
       constraints: { token: %r{[^/]+} }, format: false
  post "account/email/confirm/:token", to: "accounts#apply_email_change",   as: :apply_email_change,
       constraints: { token: %r{[^/]+} }, format: false

  # Wallet export reveal page (task #11 Stage 2). Token is a signed payload
  # from AccountsController#initiate_wallet_export; constraints stop Rails
  # from interpreting embedded periods as URL format extensions.
  get  "account/wallet/export/:token",          to: "wallet_exports#show",     as: :wallet_export,
       constraints: { token: %r{[^/]+} }, format: false
  post "account/wallet/export/:token/complete", to: "wallet_exports#complete", as: :complete_wallet_export,
       constraints: { token: %r{[^/]+} }, format: false

  # Newsletter / quest mission 2 — authed one-click join (+ web3 email capture)
  # and unsubscribe. First-ever join mints 40 seeds on-chain (Vault#grant_seeds).
  post "account/newsletter/subscribe",   to: "newsletter#subscribe",   as: :newsletter_subscribe
  post "account/newsletter/unsubscribe", to: "newsletter#unsubscribe", as: :newsletter_unsubscribe

  resources :slates, only: [:index, :show] do
    member do
      patch :update_rankings
      patch :update_turf_scores
      patch :update_formula
    end
    collection do
      get :formula_report
      get :nfl_report
      get :admin_formula
      patch :update_admin_formula
    end
  end

  get "c/:id/leaderboard_poll", to: "contests#leaderboard_poll", as: :contest_leaderboard_poll

  # Admin view of a contest — same show template, but skips the "hide picks
  # while open" guard so operators can see every entry's selections for
  # moderation. Auth via require_admin (studio-engine).
  get "contests/:id/admin", to: "contests#admin", as: :admin_contest

  resources :contests, only: [:index, :show, :new, :create, :edit, :update] do
    collection do
      get :my
      get :generator
      post :generate_bundle
      post :finalize_bundle
      post :rebuild_create_tx
      post :finalize
    end
    member do
      post :toggle_selection
      post :pick
      post :enter
      # Hold-to-confirm funding pre-check (2026-06-13): fired the instant the 2s
      # hold STARTS; a fresh authoritative balance read returns whether THIS
      # entry can be funded (token / USDC / web3 USDT). Read-only — never enters.
      post :check_funding
      post :prepare_entry
      post :stamp_entry_signature
      post :recover_pending_entry
      post :confirm_onchain_entry
      post :clear_picks
      post :grade
      post :grade_round
      post :fill
      post :lock
      post :prepare_lock_time
      post :confirm_lock_time
      post :prepare_conclusion_time
      post :confirm_conclusion_time
      post :jump
      post :simulate_game
      post :simulate_batch
      post :reset
      post :close_onchain
      post :cancel_onchain
      # Admin "Update banner" flow — swap just the hero image from a modal on
      # the contest show page (ContestsController#update_banner).
      patch :banner, action: :update_banner
      get :live
      post :prepare_onchain_contest
      post :confirm_onchain_contest
      # `post :payout_entry` was removed in the 2026-05-23 audit (H2) —
      # see ContestsController for context.
    end

    # Contest chat — create (entrants/admins) + destroy (admin soft-delete).
    resources :messages, only: [:create, :destroy] do
      # Toggle an emoji reaction on a message (add if absent, remove if the
      # viewer already reacted with it). Entrants + admins only.
      member { post :toggle_reaction }
    end

    # Edit picks on an existing entry (DB-only — chain has no opinion on
    # selections per turf-vault state.rs ContestEntry). The GET edit form
    # is served inline by contests#show via params[:edit_entry], so only
    # the update verb needs a dedicated route.
    resources :entries, only: [:update], param: :slug
  end

  resources :teams, only: [:index, :show]
  resources :players, only: [:index]
  resources :games, only: [:index]
  get "nfl/team-totals", to: "nfl_team_totals#index", as: :nfl_team_totals

  # Entry-time age gate (ENABLE_AGE_GATE) — DOB verification before first entry.
  # ALSO prompted earlier, as a step in the post-auth onboarding chain; this
  # endpoint is unchanged and remains the enforcement point either way.
  post "/age/verify", to: "age_verifications#create", as: :age_verify

  # Post-auth onboarding chain — the first-name capture and its skip now come
  # from studio-engine (Studio::OnboardingController), drawn by
  # config.draw_onboarding_routes in config/initializers/studio.rb. Same two
  # paths, same two helper names; this app no longer owns the code behind them.

  resource :wallet, only: [:show] do
    post :stripe_deposit
    post :withdraw
    post :faucet
    post :airdrop
    get  :sync
  end

  # Entry tokens (web2 contest-entry currency)
  get  "tokens/buy",             to: "tokens#buy",             as: :tokens_buy
  post "tokens/stripe_checkout", to: "tokens#stripe_checkout", as: :tokens_stripe_checkout
  # format: false — the rack-attack throttles match these paths EXACTLY;
  # without it, POST /tokens/paypal_order.json routes to the same action but
  # skips the 10/min fee-bleed throttle (and 100/min on the webhook below).
  post "tokens/paypal_order",    to: "tokens#paypal_order",    as: :tokens_paypal_order,   format: false
  post "tokens/paypal_capture",  to: "tokens#paypal_capture",  as: :tokens_paypal_capture, format: false
  # Coinflow hosted-checkout kickoff (additive rail, AppFlags.coinflow?).
  # format: false so the rack-attack fee-bleed throttle matches the exact path
  # (parity with the paypal routes above).
  post "tokens/coinflow_order",  to: "tokens#coinflow_order",  as: :tokens_coinflow_order, format: false
  # Aeropay bank-payment kickoff (additive rail, AppFlags.aeropay?). format:
  # false so the rack-attack fee-bleed throttle matches the exact path (parity
  # with the coinflow / paypal routes above).
  post "tokens/aeropay_order",   to: "tokens#aeropay_order",   as: :tokens_aeropay_order, format: false
  get  "tokens/processing",      to: "tokens#processing",      as: :tokens_processing
  get  "tokens/status",          to: "tokens#status",          as: :tokens_status
  # Lazarus audit #21: dev/test-only free-mint endpoint — not drawn in
  # production so the public mainnet app exposes no free-mint surface. The
  # tokens/buy view gates its "Mint free (dev)" button the same way.
  unless Rails.env.production?
    post "tokens/dev_mint",      to: "tokens#dev_mint",        as: :tokens_dev_mint
    # Dev/QA only: stand in for Coinflow's `Settled` webhook (which can't reach
    # localhost) so the buy -> on-chain-mint loop is demoable end-to-end on the
    # stack. Drives the same Coinflow::Fulfillment path the real webhook uses.
    post "tokens/coinflow_simulate_settle", to: "tokens#coinflow_simulate_settle", as: :tokens_coinflow_simulate_settle
    # Dev/QA only: stand in for Aeropay's `transaction_completed` webhook (which
    # can't reach localhost) so the buy -> on-chain-mint loop is demoable on the
    # stack. Drives the same Aeropay::Fulfillment path the real webhook uses.
    post "tokens/aeropay_simulate_settle", to: "tokens#aeropay_simulate_settle", as: :tokens_aeropay_simulate_settle
  end

  # Payment webhooks
  post "webhooks/stripe", to: "webhooks/stripe#create"
  post "webhooks/paypal", to: "webhooks/paypal#create", format: false
  post "webhooks/coinflow", to: "webhooks/coinflow#create", format: false
  post "webhooks/aeropay", to: "webhooks/aeropay#create", format: false

  # Coinbase CDP Onramp/Offramp — buy USDC / cash out via the Coinbase-hosted
  # widget (docs/CDP_RAMP_INTEGRATION.md §8). The routes stay drawn in every
  # env; Cdp::BaseController 404s everything unless ENABLE_CDP_RAMP is set, so
  # the env var (not a deploy) is the kill-switch. The session POSTs mint the
  # single-use widget token; OPTIONS answers strict CORS preflight for the
  # explicitly allowlisted app origins; the return GETs are Coinbase's redirectUrl targets
  # (UX signal only — never confirmation); ramp_status is the local-state poll
  # for the return page / modal. Phase 2 adds: post "webhooks/cdp".
  scope :cdp do
    match "onramp_sessions",  to: "cdp/base#preflight", via: :options
    match "offramp_sessions", to: "cdp/base#preflight", via: :options
    post "onramp_sessions",  to: "cdp/ramp_sessions#create_onramp",  as: :cdp_onramp_sessions
    post "offramp_sessions", to: "cdp/ramp_sessions#create_offramp", as: :cdp_offramp_sessions
    get  "onramp/return",    to: "cdp/returns#onramp",               as: :cdp_onramp_return
    get  "offramp/return",   to: "cdp/returns#offramp",              as: :cdp_offramp_return
    get  "ramp_status/:partner_user_ref", to: "cdp/returns#status",  as: :cdp_ramp_status,
         defaults: { format: :json }
    # Offramp send path (§10) — managed confirm-then-server-send, and the
    # Phantom prepare/sign/report loop. All keyed on partner_user_ref in the
    # body and scoped to the viewer's own offramp rows.
    post "offramp/confirm_send", to: "cdp/offramp_sends#confirm", as: :cdp_offramp_confirm_send
    post "offramp/prepare_send", to: "cdp/offramp_sends#prepare", as: :cdp_offramp_prepare_send
    post "offramp/sent",         to: "cdp/offramp_sends#sent",    as: :cdp_offramp_sent
  end

  post "add_funds", to: "users#add_funds"

  # Admin: Treasury (pending multisig transactions)
  namespace :admin do
    # User browser — refer chain, invitees count, audit columns. Read-only.
    resources :users, only: [:index]

    # Email manager lives in studio-engine now — /admin/emails is drawn by
    # Studio.routes (config.draw_admin_emails_routes). These three routes owned
    # the admin_emails / admin_email helper NAMES, which is what made the engine
    # page opt-in; removing them hands the names over.

    # OPSEC-046: admin "act as user" impersonation. POST enters (target by
    # slug), DELETE returns to the admin account. See Admin::ImpersonationsController.
    post   "impersonations/:user_slug", to: "impersonations#create",  as: :impersonate
    delete "impersonations",            to: "impersonations#destroy", as: :stop_impersonating

    # Site-wide singleton config — the main_contest pointer (SeasonConfig) plus
    # the link-preview (og:image) defaults (SiteSetting). The canonical home for
    # any global setting that doesn't fit on a per-record edit form.
    get   "dashboard", to: "dashboard#show",   as: :dashboard
    patch "dashboard", to: "dashboard#update"
    get "models", to: "models#index", as: :models
    get "models/:key", to: "models#show", as: :model
    # Link-preview (og:image) defaults — SiteSetting singleton. Text fields
    # save via the normal patch; the image is an immediate cropper save (its
    # own multipart endpoint, mirroring the contest banner flow).
    patch "dashboard/link_preview",       to: "dashboard#update_link_preview",       as: :dashboard_link_preview
    patch "dashboard/link_preview_image", to: "dashboard#update_link_preview_image", as: :dashboard_link_preview_image

    resources :outbound_requests, only: [:index, :show]

    # Error logs — read-only incident-triage browser over ErrorLog (engine model).
    # Richer than the engine's /error_logs: class facets, target_type filter,
    # summary stats, and deep-links to target/parent records. Param is the
    # error-log-<id> slug (ErrorLog#to_param).
    resources :error_logs, only: [:index, :show], param: :slug

    # Landing pages — funnel page manager (public pages live at /l/:slug)
    resources :landing_pages, only: %i[index new create edit update destroy], param: :slug do
      # Immediate cropper save for the per-page link-preview image (edit only —
      # the record must exist to attach to). Mirrors the contest banner flow.
      member do
        patch :og_image, action: :update_og_image
      end
    end

    resources :pending_transactions, only: [:index, :show], param: :slug do
      member do
        post :confirm
        post :rebuild
      end
    end

    resources :slates, only: [], param: :slug do
      member { get :manage }
    end

    # Currency registry (on-chain accepted_currencies). register / deactivate /
    # sweep are 2-of-3 → they queue a PendingTransaction for Treasury cosign.
    get  "currencies",                         to: "currencies#index",      as: :currencies
    post "currencies/register",                to: "currencies#register",   as: :register_currency
    post "currencies/:idx/deactivate",         to: "currencies#deactivate", as: :deactivate_currency
    post "currencies/sweep",                   to: "currencies#sweep",      as: :sweep_operator_revenue

    # Free entries (on-chain token minting console)
    get  "free_entries",                       to: "free_entries#index",    as: :free_entries
    post "free_entries/:user_slug/mint",       to: "free_entries#mint",     as: :mint_free_entries
    post "free_entries/mint_all",              to: "free_entries#mint_all", as: :mint_all_free_entries

    # Vault init (one-time mainnet setup — Phantom cosigns as INIT_AUTHORITY)
    get  "vault_init",                         to: "vault_init#show",       as: :vault_init
    post "vault_init/build",                   to: "vault_init#build",      as: :build_vault_init
    post "vault_init/confirm",                 to: "vault_init#confirm",    as: :confirm_vault_init

    # Vault state — pause / unpause (M5, v0.15.0). Emergency stop for
    # user-facing funds operations. 2-of-3 cosign; same direct-cosign
    # pattern as vault_init.
    get  "vault_state",                        to: "vault_state#show",      as: :vault_state
    post "vault_state/pause",                  to: "vault_state#pause",     as: :pause_vault_state
    post "vault_state/unpause",                to: "vault_state#unpause",   as: :unpause_vault_state
    post "vault_state/confirm",                to: "vault_state#confirm",   as: :confirm_vault_state

    # Seasons (on-chain seed schedule template)
    get  "seasons",                            to: "seasons#index",         as: :seasons
    post "seasons",                            to: "seasons#create"
    post "seasons/:season_id/set_current",     to: "seasons#set_current",   as: :set_current_season

    # Live goal-entry console — operator records goals (team + minute) on game
    # day. Fixtures listed here; the row forms POST to the games endpoints below.
    get "scoring", to: "scoring#index", as: :scoring

    resources :games, only: [], param: :slug do
      member do
        post :record_goal, path: "goals"
        delete :remove_goal, path: "goals/:id"
        post :complete_game, path: "complete"
      end
    end
  end

  # Admin: Link hub — central index of admin tools + actions
  get "admin/hub", to: "admin#hub", as: :admin_hub

  # Admin: Navbar review
  get "admin/navbar", to: "admin#navbar", as: :admin_navbar

  # Admin: Level badges preview gallery (1–10)
  get "admin/level_badges", to: "admin#level_badges", as: :admin_level_badges

  # Admin: Modal gallery — grid of every modal partial / state variant
  # rendered in isolated iframes (see AdminController::MODAL_VARIANTS).
  get "admin/modals", to: "admin#modals", as: :admin_modals
  get "admin/modals/preview/:modal_id", to: "admin#modal_preview", as: :admin_modal_preview
  get "admin/modals/preview_crop", to: "admin#modal_preview_crop", as: :admin_modal_preview_crop

  # Admin: Mint USDC (devnet) + balance check
  post "admin/mint_usdc", to: "admin#mint_usdc", as: :admin_mint_usdc
  get "admin/usdc_balance", to: "admin#usdc_balance", as: :admin_usdc_balance

  # Admin: Contests

  # Admin: Transaction Logs
  get "admin/transactions", to: "transaction_logs#index", as: :admin_transactions
  get "admin/transactions/:slug", to: "transaction_logs#show", as: :admin_transaction
  post "admin/transactions/:slug/approve", to: "transaction_logs#approve", as: :admin_transaction_approve
  post "admin/transactions/:slug/deny", to: "transaction_logs#deny", as: :admin_transaction_deny
  post "admin/transactions/:slug/complete", to: "transaction_logs#complete", as: :admin_transaction_complete

  # Geo — /geo/check (public, used by hold-to-confirm validation) and the
  # /admin/geo manager are drawn by Studio.routes now, behind
  # config.draw_geo_routes in config/initializers/studio.rb. The helper names are
  # unchanged (geo_check_path, admin_geo_path, admin_geo_update_path,
  # admin_geo_toggle_path), which is exactly why the engine's flag is opt-in:
  # this app held all four, and drawing them alongside these would have raised
  # `Invalid route name, already in use` at route-load.

  # Test-only endpoints — exercised by Playwright e2e specs to seed
  # OAuth mock payloads and force referral cache values without staging
  # full signup flows. Guarded to non-production so Playwright (which runs
  # against the dev server per playwright.config.js) can also reach them;
  # the controller stays unreachable in production.
  unless Rails.env.production?
    post "test/reseed",                   to: "test#reseed"
    post "test/use_phantom_mock_admin",   to: "test#use_phantom_mock_admin"
    post "test/restore_canonical_admin",  to: "test#restore_canonical_admin"
    post "test/oauth_mock",               to: "test#set_oauth_mock"
    post "test/set_user_referral_counts", to: "test#set_user_referral_counts"
    post "test/create_active_entry",      to: "test#create_active_entry"
    post "test/grant_managed_wallet",     to: "test#grant_managed_wallet"
    post "test/set_quest_state",          to: "test#set_quest_state"
    post "test/magic_link_token",         to: "test#magic_link_token"
    get  "test/user_info/:slug",          to: "test#user_info"
  end
end
