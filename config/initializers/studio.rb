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
  config.s3_bucket_prefix = "turf-monster"
end
