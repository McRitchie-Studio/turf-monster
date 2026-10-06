# Sentry — production error monitoring.
#
# Activated only when SENTRY_DSN env var is set. In dev/test, leave SENTRY_DSN
# unset to avoid noisy issue creation.
#
# Setup steps (operator):
#   1. Create a Sentry project at https://sentry.io for the "turf-monster" app
#   2. Copy the DSN from Project Settings → Client Keys (DSN)
#   3. `heroku config:set SENTRY_DSN=https://...@sentry.io/... --app turf-monster-mainnet`
#   4. Restart dynos: `heroku restart --app turf-monster-mainnet`
#
# Optional env vars:
#   SENTRY_TRACES_SAMPLE_RATE — 0.0 (default) to 1.0; performance traces sampling
#   HEROKU_SLUG_COMMIT — auto-set by Heroku, used as release identifier
if ENV["SENTRY_DSN"].present?
  Sentry.init do |config|
    config.dsn = ENV["SENTRY_DSN"]
    config.breadcrumbs_logger = [:active_support_logger, :http_logger]
    config.traces_sample_rate = (ENV["SENTRY_TRACES_SAMPLE_RATE"] || 0.0).to_f
    config.environment = ENV["SENTRY_ENVIRONMENT"] || Rails.env
    config.release = ENV["HEROKU_SLUG_COMMIT"] || ENV["GIT_COMMIT"]
    config.send_default_pii = false
    config.send_modules = false
  end

  # A Redis cache outage reports through Rails.error (CacheErrorReporter); this
  # sends those reports, and only those, to Sentry.
  Rails.application.config.after_initialize { CacheErrorReporter.subscribe_sentry! }
end
