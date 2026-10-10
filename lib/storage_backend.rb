# frozen_string_literal: true

# OBJECT STORAGE IS CLOUDFLARE R2, AND ONLY R2. AWS S3 is retired (no key, no
# bucket), so there is no s3 or mirror stage to select: one could only crash
# (turf-storage-runs-r2-only). The fleet's rules are mcritchie-studio's
# docs/agents/modules/object-storage.md.
#
# Two config vars survive from the move, and both now have exactly one value:
#
#   ACTIVE_STORAGE_BACKEND  r2   read by config/storage.yml
#   STUDIO_S3_BACKEND       r2   read by config/initializers/studio.rb through
#                                .studio_s3_settings (Studio::S3: email banners,
#                                cached headshots)
#
# UNSET MEANS R2. Any other value RAISES at boot, naming the variable: a dyno
# still carrying `s3` or a mirror stage from the move would otherwise look
# configured while pointing at a store that no longer exists.
#
# The connection comes from four variables (1Password item r2.turf-monster: the
# prod pair on production, the dev pair on QA and in local development):
#
#   R2_ENDPOINT  R2_ACCESS_KEY_ID  R2_SECRET_ACCESS_KEY  R2_PUBLIC_URL
#
# R2_PUBLIC_URL is as required as the keys. This app serves raw object URLs to
# strangers (og:images to link unfurlers, email banners to inboxes, headshots to
# every visitor) and R2 serves an object anonymously only through a domain
# attached to its bucket.
#
# WHO MUST HOLD THEM (.r2_required?):
#   production   always. QA boots RAILS_ENV=production too, so this covers both
#                deployed apps. A missing variable raises at boot, by name.
#   elsewhere    only once ANY of the four is set (a laptop's .env.development).
#                Then all four are required, so half a configuration fails by
#                name instead of at the first upload.
#   keyless      test, CI, and a development boot with none of the four. No
#                remote service is defined (Active Storage stays on Disk) and
#                Studio::S3 is pointed at an endpoint that cannot resolve, with
#                placeholder keys, so nothing falls back to the AWS SDK's
#                default endpoint or its credential chain.
module StorageBackend
  BACKEND = "r2"
  R2_VARIABLES = %w[R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_PUBLIC_URL].freeze

  # The public domains attached to the two buckets (the same values the deployed
  # apps hold as R2_PUBLIC_URL; object-storage.md's fleet census).
  PRODUCTION_PUBLIC_URL = "https://assets.turfmonster.media"
  DEV_PUBLIC_URL = "https://assets-dev.turfmonster.media"

  # Where a keyless process's Studio::S3 client points. `.invalid` is reserved
  # (RFC 2606) and never resolves, so a write from an unconfigured laptop fails
  # on the spot rather than reaching AWS through the SDK's default endpoint. The
  # placeholder key pair is not a credential: it stops the SDK walking its
  # default chain (~/.aws, then an instance-metadata lookup that hangs in CI).
  # Reads still render, from the dev bucket's public domain.
  UNCONFIGURED_ENDPOINT = "https://r2-not-configured.invalid"
  UNCONFIGURED_KEY = "r2-not-configured"
  UNCONFIGURED_SETTINGS = {
    s3_endpoint: UNCONFIGURED_ENDPOINT, s3_region: "auto",
    s3_access_key_id: UNCONFIGURED_KEY, s3_secret_access_key: UNCONFIGURED_KEY,
    s3_public_url: DEV_PUBLIC_URL
  }.freeze

  module_function

  def active_storage_stage(env = ENV)
    backend(env, "ACTIVE_STORAGE_BACKEND")
  end

  def studio_s3_stage(env = ENV)
    backend(env, "STUDIO_S3_BACKEND")
  end

  # Whether this process must hold a complete R2 configuration.
  def r2_required?(env = ENV, production: production?)
    production || R2_VARIABLES.any? { |name| env[name].to_s.strip != "" }
  end

  # Whether development talks to the remote dev bucket (amazon_dev /
  # amazon_public_dev) rather than Disk: whenever R2 is configured at all.
  def remote_in_development?(env = ENV)
    r2_required?(env, production: false)
  end

  # The four R2 values by variable name, or nil for a keyless non-production
  # process. Raises, naming the first missing variable, when R2 is required.
  def r2_connection(env = ENV, production: production?)
    return nil unless r2_required?(env, production: production)

    R2_VARIABLES.to_h { |name| [ name, require!(env, name) ] }
  end

  # The whole storage configuration, checked in one call at boot
  # (config/initializers/studio.rb), so a bad value stops the process there
  # rather than whenever config/storage.yml is first parsed.
  def verify!(env = ENV, production: production?)
    active_storage_stage(env)
    studio_s3_stage(env)
    r2_connection(env, production: production)
    true
  end

  # The Studio.configure settings for Studio::S3.
  def studio_s3_settings(env = ENV, production: production?)
    studio_s3_stage(env)
    r2 = r2_connection(env, production: production)
    return UNCONFIGURED_SETTINGS unless r2

    {
      s3_endpoint: r2.fetch("R2_ENDPOINT"),
      s3_region: "auto",
      s3_access_key_id: r2.fetch("R2_ACCESS_KEY_ID"),
      s3_secret_access_key: r2.fetch("R2_SECRET_ACCESS_KEY"),
      s3_public_url: r2.fetch("R2_PUBLIC_URL")
    }
  end

  def backend(env, name)
    value = env[name].to_s.strip
    return BACKEND if value.empty? || value == BACKEND

    raise ArgumentError, "#{name}=#{value.inspect} is not supported: AWS S3 was retired on 2026-10-10 and this " \
                         "app stores objects on Cloudflare R2 only. Set #{name}=#{BACKEND} or unset it."
  end

  def require!(env, name)
    value = env[name].to_s.strip
    raise ArgumentError, "#{name} must be set: this app stores objects on Cloudflare R2 (lib/storage_backend.rb)" if value.empty?

    value
  end

  def production?
    defined?(Rails) && Rails.respond_to?(:env) && Rails.env.production?
  end
end
