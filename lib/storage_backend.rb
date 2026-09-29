# frozen_string_literal: true

# THE MOVE OFF AWS S3 ONTO CLOUDFLARE R2 (asset-library Wave 2; the recipe is
# mcritchie-studio's docs/agents/system/asset-library-plan.md, and this module is
# the one mcritchie-industries and moms-app already moved with). Two switches,
# both config vars, both inert until set, so this code ships before the move and
# each step of the move is a config change rather than a deploy:
#
#   ACTIVE_STORAGE_BACKEND  s3 (default) → mirror_to_r2 → mirror_to_s3 → r2
#     Read by config/storage.yml, and by config/environments/development.rb
#     and OgImageAttachable through .remote_in_development?. The four services blob rows name (amazon,
#     amazon_dev, amazon_public, amazon_public_dev) keep their NAMES through all
#     four stages; only what they resolve to changes, so no blob row is ever
#     rewritten. The two mirror stages write both stores, which is what makes
#     Active Storage's half of the move reversible by config.
#
#   STUDIO_S3_BACKEND       s3 (default) | r2
#     Read by config/initializers/studio.rb through .studio_s3_settings below.
#     Studio::S3 (email banners) writes to exactly one store, so it moves in ONE
#     step, followed at once by a catch-up copy of anything written since.
#
# R2 connection details come from R2_ENDPOINT, R2_ACCESS_KEY_ID and
# R2_SECRET_ACCESS_KEY (the prod pair on production, the dev pair on QA; both in
# 1Password item r2.turf-monster). Bucket NAMES are the same on both stores.
#
# UNLIKE INDUSTRIES, R2_PUBLIC_URL IS REQUIRED on any R2 stage. This app serves
# raw object URLs to strangers: og:images to link unfurlers (OgImageAttachable)
# and email banners to inboxes (Studio::S3.url). R2 serves an object anonymously
# only through a domain attached to its bucket, so without one those URLs would
# 400; better to refuse at boot than to ship broken previews.
#
# An unknown value RAISES at boot rather than falling back to S3: a typo in a
# config var would otherwise look like a successful flip while every write kept
# landing on the old store.
module StorageBackend
  ACTIVE_STORAGE_STAGES = %w[s3 mirror_to_r2 mirror_to_s3 r2].freeze
  STUDIO_S3_STAGES = %w[s3 r2].freeze

  module_function

  def active_storage_stage(env = ENV)
    stage(env, "ACTIVE_STORAGE_BACKEND", ACTIVE_STORAGE_STAGES)
  end

  def studio_s3_stage(env = ENV)
    stage(env, "STUDIO_S3_BACKEND", STUDIO_S3_STAGES)
  end

  # Whether development talks to a remote bucket (amazon_dev / amazon_public_dev)
  # rather than Disk: AWS keys on the S3 stage, as before; any other stage has
  # already required its R2 keys in config/storage.yml.
  def remote_in_development?(env = ENV)
    active_storage_stage(env) != "s3" || env["AWS_ACCESS_KEY_ID"].to_s.strip != ""
  end

  # The Studio.configure settings for the current stage: {} on S3 (the engine's
  # defaults, exactly as before), the R2 connection and public domain on r2.
  def studio_s3_settings(env = ENV)
    return {} if studio_s3_stage(env) == "s3"

    {
      s3_endpoint: require!(env, "R2_ENDPOINT"),
      s3_region: "auto",
      s3_access_key_id: require!(env, "R2_ACCESS_KEY_ID"),
      s3_secret_access_key: require!(env, "R2_SECRET_ACCESS_KEY"),
      s3_public_url: require!(env, "R2_PUBLIC_URL")
    }
  end

  def stage(env, name, allowed)
    value = env[name].to_s.strip
    return allowed.first if value.empty?
    return value if allowed.include?(value)

    raise ArgumentError, "#{name}=#{value.inspect} is not one of #{allowed.join(', ')}"
  end

  def require!(env, name)
    value = env[name].to_s.strip
    raise ArgumentError, "#{name} must be set when a storage backend is r2" if value.empty?

    value
  end
end
