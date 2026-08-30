# Passwordless (Lazarus audit #4): this app removed has_secure_password — email
# auth is magic-link only (wallet auth via SolanaSessionsController unchanged).
# The studio-engine User contract still requires User#authenticate, which no
# longer exists, so we opt out of the contract check. The engine's password
# SessionsController#create is fully overridden by the host (bounces to the
# magic-link flow), so no engine code path relies on #authenticate here.
Studio.validate_user_contract = false

# This app defines its own magic_link + solana routes (with extras like
# email_verification, phantom_callback, google_popup, link_wallet) in
# config/routes.rb, so the engine must NOT also draw its magic_link/solana
# routes — that would collide on the `magic_link` route NAME and crash boot.
# (studio-engine >= 0.5.1)
Studio.draw_auth_routes = false

# Use the unified Studio::Link store for magic links (short tokens, shared model).
# turf-monster keeps its own rich /magic_link route + controller (contest landing,
# age-gate, picks) — now backed by Studio::Link.
Studio.magic_link_store = :database

# Don't let the engine draw its /l routes — turf needs its OWN gated handler.
# This app draws /l/<token> -> its own Studio::LinksController (config/routes.rb),
# whose magic-link consume goes through turf's legal-age-gated sign_up_new, NOT the
# engine's gateless one. Landing pages moved to /lp so /l is the unified
# Studio::Link entry point (magic + referral). Engine drawing /l too would re-add
# the gateless consume path.
Studio.draw_link_routes = false

Studio.configure do |config|
  config.app_name = "Turf Monster"
  config.sticky_table_headers = true

  # Smooth-load convention (engine 0.24): same-origin view transitions +
  # turbo-cache-control no-preview metas via the engine layout contract.
  config.smooth_load = true

  # nav_spinner_min_ms is a minimum DISPLAY FLOOR, not a timeout: the engine
  # computes remaining = max(0, min_ms - elapsed), so a slow op (Solana RPC
  # included) already exceeds any floor and is unaffected — the floor only
  # pads FAST navigations so a sub-floor load doesn't flash the spinner.
  # Per the engine's smooth-load guidance, drop it to 300ms so fast loads
  # absorb flicker without the spinner lingering after every turbo:load.
  config.nav_spinner_min_ms = 300
  config.session_key = :turf_user_id
  config.welcome_message = ->(user) { "Welcome to Turf Totals, #{user.display_name}!" }
  # Passwordless: email auth is magic-link only. Permit just :email (+ funnel
  # reference) so the engine's POST /signup path can't choke on now-unsupported
  # password params (there is no password= setter anymore).
  config.registration_params = [:email, :reference]
  config.configure_new_user = ->(user) { }
  config.configure_sso_user = ->(user) { }

  # On-chain app: Solana wallet auth (SIWS) + USDC/seeds/vault, plus the
  # seeds→levels system. Without :web3 the engine hides the wallet sign-in
  # button (auth_method?(:wallet) && feature?(:web3)) and marks Web3 surfaces
  # disabled on this app.
  config.features = %i[web3 leveling]

  # Passwordless + wallet: magic-link, Google OAuth, and Solana wallet are all
  # real sign-in methods (no password). Equals the engine default — pinned
  # explicitly so a future default change can't silently drop wallet.
  config.auth_methods = %i[magic_link google wallet]

  # WHICH column a wallet signs in with. Declaring :wallet above is only half the
  # statement — the engine will not guess the column, and until this line existed
  # Studio::OauthIdentity.wallet_present? was always false here, so a wallet-only
  # account reported NO remaining sign-in method and was refused a Google unlink
  # that User#has_authentication_method explicitly permits.
  #
  # :web3_solana_address, NOT :solana_address. That reader is
  # `web3_solana_address || web2_solana_address`, and the web2 address is
  # CUSTODIAL — held by the platform, with no signer. Naming it here would count
  # an address nobody can sign with as a way back into the account and permit an
  # unlink that orphans it. test/initializers/studio_wallet_method_test.rb asserts
  # that property rather than this spelling.
  config.wallet_address_method = :web3_solana_address

  # THE PHANTOM CALLBACK'S ON-PAGE DEBUG SINK. Restores exactly what this app had
  # before /tasks/adopt-engine-phantom-deeplink deleted its fork of the callback
  # view. The engine DEFAULTS THIS OFF and the default is the point: the sink
  # prints phantom_dl_secret's presence and every other phantom_dl_* key to the
  # page and the console on every mobile sign-in, so a capability sitting next to
  # a signing key is opted into, never defaulted on.
  #
  # AppFlags.live_production? is production-AND-not-QA — the same predicate the
  # OPSEC-020 kill-switches use — so QA keeps its debugging. Rails.env.production?
  # is NOT a substitute: a Heroku QA dyno runs RAILS_ENV=production, which would
  # take QA's debugging away silently. Omitting this line loses the sink the same
  # silent way, which is why test/integration/phantom_callback_debug_gate_test.rb
  # asserts BOTH branches rather than only the production one.
  #
  # The value never leaks even when the sink renders: the callback redacts
  # SECRET_KEYS at the point of display (test/lib/phantom_callback_secret_redaction_js_test.rb).
  config.wallet_debug_sink = -> { !AppFlags.live_production? }

  # THE PROFILE PAGE'S ROWS: the engine's defaults, plus this app's own Quests card.
  #
  # THE NEWSLETTER ROW IS BACK. It was held off this page because the engine's row
  # writes joined_email_list_at directly, and this app's 25-seed welcome bonus is
  # gated on User#first_newsletter_join? — literally `joined_email_list_at.nil?`.
  # A subscribe on /profile therefore set the column, granted no seeds, and left
  # the bonus unclaimable forever. Studio.after_newsletter_change (engine 0.53.0)
  # closes that: the grant now runs from the callback below, so joining from
  # either page pays exactly once. See the callback for the ordering that makes
  # `first_join` meaningful.
  #
  # QUESTS ARE THIS APP'S OWN, and the engine has no concept of them by design —
  # they are seeds-shaped, and seeds do not belong in a gem four other apps
  # install. The registry takes a host row naming a host partial, so the card that
  # already renders on /account renders here unchanged.
  #
  # Composed against Studio.default_profile_sections rather than a literal list,
  # so a row the engine adds later arrives here automatically.
  config.profile_sections = lambda do |_view|
    # THIS APP REPLACES THE ENGINE'S NEWSLETTER ROW WITH ITS OWN. The engine's is
    # a plain form plus a confirm dialog — right for an app with no rewards, wrong
    # for this one, where joining is worth 25 seeds and leaving costs them. This
    # app already walks people through that with a five-modal flow (subscribe →
    # success, unsubscribe-confirm → goodbye, plus the web3 email capture), all
    # registered on the shared $store.modals host in layouts/application.html.erb
    # and therefore already mounted on /profile.
    #
    # Replaced by KEY rather than rejected-and-appended, so it keeps the engine's
    # POSITION in the list instead of being shuffled to the end.
    ours = { key: :newsletter, title: "Newsletter", page: :show,
             partial: "accounts/newsletter_section" }

    rows = Studio.default_profile_sections.map do |section|
      section[:key] == :newsletter ? ours : section
    end

    # THE WEB3 ROWS, and the direction they represent. /profile is this app's new
    # account page and /account is being emptied onto it a card at a time
    # (operator's call) — these two are that migration, not a duplication: both
    # pages render the SAME partial, so there is one implementation to keep right
    # while the two pages coexist.
    #
    # NONE OF IT BELONGS IN THE ENGINE. Wallets, entry tokens and seeds are this
    # app's, the same ruling that kept quests out — a gem four other apps install
    # has no business knowing what a seed is.
    rows + [
      # THE WALLET KEEPS ITS TITLE, so the row supplies an h2 and the partial
      # stays chrome-free. It self-gates on solana_connected? and offers the
      # CONNECT button when there is no wallet, which is why there is no `if:`
      # here: a row-level gate would drop the card entirely and leave an account
      # with no wallet no way to link one from this page.
      { key: :solana_wallet, title: "Solana Wallet", page: :show,
        partial: "accounts/solana_wallet_section" },

      # THE REFERRAL ROW HAS NO TITLE, deliberately. Its heading carries an info
      # toggle and three share targets, which a section title cannot express — so
      # the partial keeps its own header and the row renders the card around it.
      # `title:` omitted rather than blank: the engine's row only emits an h2
      # `if section[:title].present?`.
      { key: :referral, page: :show, partial: "accounts/referral_section" },

      # QUESTS ARE THIS APP'S OWN and the engine has no concept of them by design —
      # they are seeds-shaped, and seeds do not belong in a gem four other apps
      # install.
      { key: :quests, title: "Quests", page: :show, partial: "accounts/quests" }
    ]
  end

  # THE SEEDS HALF OF A NEWSLETTER JOIN, which the engine deliberately knows
  # nothing about.
  #
  # `first_join` is computed by the engine BEFORE it writes the column — asked
  # afterwards it would always be false and this bonus could never be paid.
  #
  # A SAFETY NET, NOT THE MECHANISM — and worth knowing which. Both cards on both
  # pages open this app's modals, which POST to newsletter_subscribe_path and are
  # granted seeds by NewsletterController directly. Nothing in the UI reaches the
  # engine's POST /profile/newsletter, so this callback does not fire today.
  #
  # It is wired anyway because the engine's route is public and may grow its own
  # UI, and a subscribe arriving there WITHOUT this would set joined_email_list_at,
  # grant nothing, and burn first_newsletter_join? forever — the exact bug the row
  # was held off /profile for.
  #
  # NO DOUBLE GRANT either way: the two paths are disjoint, both call the same
  # NewsletterSeedGrant, and the on-chain SeedGrant[newsletter] PDA refuses a
  # second grant regardless — so the worst case of any mistake here is a no-op,
  # never a double payout.
  config.after_newsletter_change = lambda do |user, subscribed:, first_join:|
    NewsletterSeedGrant.call(user) if subscribed && first_join
  end

  config.mailer_from = Studio.mailer_from_for_transport(
    ses_from: "Turf Monster <team@turfmonster.media>"
  )

  config.theme_logos = [
    { file: "favicon.png",   title: "Favicon" },
    { file: "logo.png",      title: "Navbar Logo" },
    { file: "logo.jpeg",     title: "Auth Logo" },
  ]

  # Theme: green primary, violet as accent2
  config.theme_primary = "#4BAF50"
  config.theme_accent = "#8E82FE"

  # S3 — overrides engine default ("mcritchie-studio") to use this app's bucket
  # Draw the shared email manager at /admin/emails (studio-engine). Turf Monster
  # used to own this path with its own Admin::EmailsController; that page and its
  # routes are gone, so the engine's — which does everything the old one did plus
  # banner management — takes the URL.
  config.draw_admin_emails_routes = true

  # Draw the engine's first-name onboarding endpoints. This app used to own both
  # routes and their controller; they are deleted in the same change, which is
  # what frees the names for the gem. The engine's flag is opt-in precisely
  # BECAUSE this app held them — drawing them here before the deletion would
  # raise `Invalid route name, already in use` at route-load and take down every
  # route in the app.
  config.draw_onboarding_routes = true

  # What the engine's endpoints report back as still-remaining after the name is
  # saved or skipped. The engine owns the STEP; this app owns the SEQUENCE, and
  # this is that seam — turf walks first name → age → wallet, which means nothing
  # in a hub app.
  #
  # (It used to pass `welcome: false` here, since that beat was behind us by
  # definition once a first-name call was being answered. The welcome step was
  # retired on 2026-08-15 and OnboardingFlow no longer takes the argument.)
  config.onboarding_steps_resolver = lambda { |user, session|
    OnboardingFlow.steps_for(
      user,
      skipped_first_name: session[Studio::FIRST_NAME_SKIP_SESSION_KEY] == true,
      age_gate_enabled: AppFlags.age_gate?
    )
  }

  config.s3_bucket_prefix = "turf-monster"

  # ---- Geo (studio-engine >= 0.57 — see the gem's docs/GEO.md) -------------
  #
  # This app used to carry the whole stack: GeoSetting, GeoHelper,
  # GeoSettingsController, the badge, the geocoder initializer and the detection
  # methods on ApplicationController. All of it is the engine's now; what stays
  # here is the POLICY, and in the controllers, the DECISION of what to lock.

  config.geo_home_country = "US"

  # The legal exclusion list this app enforces before an operator has saved one
  # at /admin/geo. CA was added 2026-06 (underwriting compliance): the 2025
  # California AG opinion treats paid fantasy contests as unlawful, so it sits
  # alongside the legacy DFS-prohibited states.
  #
  # NOTE, unchanged by this move: seeds use find_or_create_by!, so an EXISTING
  # row (production) does NOT pick up an addition here — the operator must add it
  # at /admin/geo before relying on it.
  config.geo_default_banned_subdivisions = %w[WA ID MT LA AZ HI NV CA]

  # Loopback never geocodes, so without this every geo-gated feature (the CDP
  # ramp catalog, the entry gate) fails closed on a developer's own machine.
  config.geo_development_region = ENV.fetch("DEV_GEO_STATE", "CO")

  # /admin/geo's simulator pins a session to a blocked state so the blocked
  # experience can be walked without a VPN. WA, because that is the state the
  # e2e specs drive.
  config.geo_simulated_region = "US-WA"

  # The copy a blocked visitor reads. "state" rather than the engine default's
  # "area": this app's rules are US state rules, and that is the word the Terms
  # and /state-eligibility use.
  config.geo_blocked_message = lambda { |subdivision, _country|
    place = subdivision.present? ? " (#{subdivision})" : ""
    "This feature is not available in your state#{place}."
  }

  # Draw /admin/geo + /geo/check from the engine. Opt-in there because THIS app
  # owned all four helper names until the routes above were deleted.
  config.draw_geo_routes = true
end
