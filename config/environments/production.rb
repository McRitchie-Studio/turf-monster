require "active_support/core_ext/integer/time"
require Rails.root.join("lib/turf_monster/host_config").to_s

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot. This eager loads most of Rails and
  # your application in memory, allowing both threaded web servers
  # and those relying on copy on write to perform better.
  # Rake tasks automatically ignore this option for performance.
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true

  # Ensures that a master key has been made available in ENV["RAILS_MASTER_KEY"], config/master.key, or an environment
  # key such as config/credentials/production.key. This key is used to decrypt credentials (and other encrypted files).
  # config.require_master_key = true

  # Disable serving static files from `public/`, relying on NGINX/Apache to do so instead.
  # config.public_file_server.enabled = false

  # Compress CSS using a preprocessor.
  # config.assets.css_compressor = :sass

  # Do not fall back to assets pipeline if a precompiled asset is missed.
  config.assets.compile = false

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Specifies the header that your server uses for sending files.
  # config.action_dispatch.x_sendfile_header = "X-Sendfile" # for Apache
  # config.action_dispatch.x_sendfile_header = "X-Accel-Redirect" # for NGINX

  # Store uploaded files on S3 in production (see config/storage.yml for options).
  config.active_storage.service = :amazon

  # Mount Action Cable outside main process or domain.
  # config.action_cable.mount_path = nil
  # config.action_cable.url = "wss://example.com/cable"
  # APP_HOST is the canonical public hostname for this deployment. APP_HOST_ALIASES
  # keeps legacy domains accepted while provider allowlists are updated.
  # Drives: ActionCable origin allowlist, mailer/OAuth-callback default_url_options,
  # the host-authorization allowlist below, and — through the same ENV var and the
  # same default constant — the ROUTE SET's default_url_options, which is what
  # out-of-request URL helpers (Turbo broadcasts, jobs) read
  # (config/initializers/route_default_url_options.rb).
  app_host = ENV.fetch("APP_HOST", TurfMonster::HostConfig::DEFAULT_APP_HOST)
  app_host_aliases = TurfMonster::HostConfig.aliases(ENV.fetch("APP_HOST_ALIASES", ""))
  app_hosts = TurfMonster::HostConfig.public_hosts(app_host:, aliases: app_host_aliases)

  # ActionCable (contest chat) — restrict WebSocket origins to app-owned hosts.
  config.action_cable.allowed_request_origins = TurfMonster::HostConfig.allowed_https_origins(app_hosts)

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # Can be used together with config.force_ssl for Strict-Transport-Security and secure cookies.
  # config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT by default
  config.logger = ActiveSupport::Logger.new(STDOUT)
    .tap  { |logger| logger.formatter = ::Logger::Formatter.new }
    .then { |logger| ActiveSupport::TaggedLogging.new(logger) }

  # Prepend all log lines with the following tags.
  config.log_tags = [ :request_id ]

  # "info" includes generic and useful information about system operation, but avoids logging too much
  # information to avoid inadvertent exposure of personally identifiable information (PII). If you
  # want to log everything, set the level to "debug".
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Shared Redis cache (Lazarus audit #11). Was :memory_store — per-dyno and
  # wiped on restart, which silently broke rack-attack throttles (login / faucet
  # / Stripe / etc.): per-dyno counters that never aggregate and reset on every
  # deploy, so the limits were effectively off in prod. Redis is shared +
  # cross-process, so they work correctly. (MagicLink single-use no longer rides
  # Rails.cache — it's a DB `consumed_at` column now; see app/models/magic_link.rb.)
  # Shares the Sidekiq Redis (REDIS_URL), namespaced to avoid key collisions; the
  # error_handler degrades gracefully (a Redis blip logs instead of 500ing).
  cache_redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
  cache_store_options = {
    url: cache_redis_url,
    namespace: "tm-cache",
    expires_in: 90.minutes,
    reconnect_attempts: 1,
    error_handler: ->(method:, returning:, exception:) {
      Rails.logger.error("[cache] #{method} failed: #{exception.class}: #{exception.message}")
    }
  }
  # Heroku Redis serves rediss:// (TLS) with a self-signed cert; redis-client
  # verifies peer certs by default and would REJECT it. Because the error_handler
  # above swallows the connection error, that failure would be SILENT — every
  # Rails.cache op returns nil/false, which no-ops every rack-attack throttle
  # (counters never increment, so the limits are off). Mirror config/initializers/sidekiq.rb:
  # keep the connection encrypted, skip chain verification (Heroku's documented
  # guidance for their Redis add-on).
  if cache_redis_url.start_with?("rediss://")
    cache_store_options[:ssl_params] = { verify_mode: OpenSSL::SSL::VERIFY_NONE }
  end
  config.cache_store = :redis_cache_store, cache_store_options

  # Background jobs via Sidekiq (worker dyno + Heroku Redis).
  # NB1 (audit 2026-05-23): was :async, which ran jobs in the web dyno's
  # thread pool. Jobs were lost on dyno restart (Heroku restarts daily) and
  # slow Solana RPC jobs starved Puma worker threads. The Sidekiq worker dyno
  # in the Procfile was sitting idle except for the cron sweeper.
  config.active_job.queue_adapter = :sidekiq

  # Disable caching for Action Mailer templates even if Action Controller
  # caching is enabled.
  config.action_mailer.perform_caching = false

  # OPSEC-005: production delivery is selected by Studio::MailTransport.
  # SES uses MAILER_FROM; Resend fallback uses RESEND_MAILER_FROM.
  # The sending domain must be verified by the active transport.
  config.action_mailer.default_url_options = { host: ENV.fetch("MAILER_HOST", app_host), protocol: "https" }
  # Branded email banners are served from this app's own asset pipeline
  # (app/assets/images/emails/*.png) — absolute URLs for inbox rendering.
  config.action_mailer.asset_host = "https://#{ENV.fetch('MAILER_HOST', app_host)}"
  config.action_mailer.raise_delivery_errors = true
  config.action_mailer.perform_deliveries = true

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Prelaunch audit C4 (2026-05-24): enable DNS-rebinding + Host-header
  # protection. Without this, Rails 7 accepts any Host header, which lets
  # attackers replay Stripe-signed webhook payloads against the dyno's direct
  # *.herokuapp.com URL (bypassing CDN/WAF allowlists) and enables DNS-rebinding
  # to reach the app under a foreign origin's cookie scope.
  # Primary public hosts (APP_HOST + APP_HOST_ALIASES) + this app's direct Heroku
  # dyno host. The dyno host is parameterized via DYNO_HOST so the Heroku app
  # authorizes its own *.herokuapp.com without a code change. Avoid the HEROKU_*
  # namespace, which the platform reserves and may clobber.
  config.hosts = [
    *app_hosts,                                                                # public URLs
    ENV.fetch("DYNO_HOST", "turf-monster-mainnet-1c0aa8261ff8.herokuapp.com"), # direct Heroku dyno URL (health checks, etc.)
  ].uniq
  # /up is the Rails health-check endpoint Heroku polls — Heroku's load balancer
  # may use internal addressing, so exclude it from host authorization to avoid
  # false-positive health-check failures.
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
