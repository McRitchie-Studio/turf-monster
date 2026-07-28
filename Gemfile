source "https://rubygems.org"

ruby "3.3.11"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.0"
# The original asset pipeline for Rails [https://github.com/rails/sprockets-rails]
gem "sprockets-rails"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"
# Redis adapter for Action Cable — powers contest chat real-time delivery.
gem "redis", ">= 4.0.1"

# Use Kredis to get higher-level data types in Redis [https://github.com/rails/kredis]
# gem "kredis"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.7"

# Google OAuth
gem "omniauth"
gem "omniauth-google-oauth2"
gem "omniauth-rails_csrf_protection", "~> 1.0"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ mswin mswin64 mingw x64_mingw jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"
gem "aws-sdk-s3", require: false

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri mswin mswin64 mingw x64_mingw ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  # Pretty-print Stripe payloads + on-chain responses in tagged dev logs.
  gem "amazing_print"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Pin minitest to the 5.x line. minitest 6.0 extracted `minitest/mock`
  # (Minitest::Mock + Object#stub) into a separate gem; the suite relies on
  # `.stub` extensively. Rails 8.1 only requires minitest >= 5.15, so we stay
  # on the well-understood 5.x series and keep this upgrade scoped to Rails.
  gem "minitest", "~> 5.25"

  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
  # I1 (Stage 3 audit): code coverage. Opt-in via COVERAGE=1 — see test_helper.rb.
  gem "simplecov", require: false
end
gem "dotenv-rails", groups: [:development, :test]
gem "tailwindcss-rails", "~> 4.5"
# Sidekiq + scheduled jobs (Reconciler cron, ATA ensure jobs, deposit jobs)
gem "sidekiq-cron", "~> 1.12"

# Sentry — production error monitoring. ErrorLog.capture! fans out to Sentry
# when SENTRY_DSN env var is set. No-op if absent.
gem "sentry-ruby"
gem "sentry-rails"

# Shared Rails engine: auth, theme, error logs, SSO, and the unified
# Studio::Link store (short tokens for magic links + referral invites).
# 0.11.0 widens the Rails bound to allow 8.1; it also ships the opt-in
# Studio::Enumeral table (0.9.0) and the Studio::Redis / Studio::Cable
# websocket primitives (0.10.0), neither of which turf adopts yet.
gem "studio-engine", "~> 0.20" # 0.20 homes the shared modal-block superset TM now renders instead of forking: the entry-confirmed celebration + seeds bar + digit reel + free-entry-earned blocks and the wallet brand sprite, all gated behind config.features %i[web3 leveling] (TM enables both); 0.19 ships the dev-only /_studio/local_review mint endpoint (the local half of the board WAITING APPROVAL button — turf stacks host most local demos); 0.18 ships the /admin/style Design System page + engine-motion.css (opt-in motion/effect layer, generated via lib/tasks/tailwindcss_engine_motion.rake); 0.15 made btn-secondary/btn-neutral token-driven (--btn-* custom props) so TM expresses its violet secondary via :root tokens instead of forking

# Solana primitives (Client, Keypair, Borsh, Transaction, AuthVerifier)
# 0.4.7 adds Solana::Transaction.cosign_wire + Client#simulate_transaction for the
# Phantom-first signing-order flow (published to RubyGems).
gem "solana-studio", "~> 0.4.7"

# IP geolocation for state-level geo-blocking
gem "geocoder"

# Random username generation for new wallet-only users (via Studio::UsernameGenerator)
gem "faker"

# Background jobs
gem "sidekiq"

# Payment processing
gem "stripe"

# EdDSA (Ed25519) signing for JWTs — required by Cdp::Auth for Coinbase CDP
# Onramp/Offramp REST auth. jwt 3.x extracted EdDSA support into this gem;
# vanilla jwt raises JWT::EncodeError ("Unsupported signing method") without it.
# Pinned: third-party gem (anakinj) sitting on the CDP secret-key signing path.
# See docs/CDP_RAMP_INTEGRATION.md §1.
gem "jwt-eddsa", "~> 0.9"

# Request throttling (OPSEC-019). Rack middleware that rate-limits per IP /
# per user / per endpoint. Configured in config/initializers/rack_attack.rb.
# Disabled in test env (so tests don't hit throttles by accident).
gem "rack-attack"
