# Shared resolver for the Active Storage service that backs og:image
# (link-preview) attachments.
#
# Why a constant and not just `service: :amazon_public` on each model:
# has_one_attached's `service:` option is a LITERAL service name, resolved once
# when the macro runs at class load. It can't switch per-env on its own. We
# need three different services depending on the environment (test must stay on
# Disk so the suite never touches a bucket or needs R2 keys; prod/dev need the
# matching public bucket), so the env switch has to be computed here.
#
# This mirrors the private-service selection in config/environments/*.rb
# (`config.active_storage.service`), but points at the PUBLIC (`public: true`)
# variants from config/storage.yml so `attachment.url` is a permanent, absolute
# URL on the bucket's public domain — unfurlers (Apple/Twitter/Slack) cache the og:image URL, and a signed
# expiring URL from the private `amazon` service would break the preview once
# the signature lapses.
#
#   test         -> :test               (Disk, tmp/storage — no network/creds)
#   production    -> :amazon_public       (turf-monster-production; the dev
#                    bucket on QA, which also boots as production)
#   development   -> :amazon_public_dev   (turf-monster-dev) when R2 is
#                    configured (StorageBackend.remote_in_development?), else
#                    :local
module OgImageAttachable
  # Bare value module (just the constant below) — no `included do`, so it needs
  # no ActiveSupport::Concern. Models read OgImageAttachable::PUBLIC_OG_SERVICE.

  PUBLIC_OG_SERVICE =
    if Rails.env.test?
      :test
    elsif Rails.env.production?
      :amazon_public
    elsif StorageBackend.remote_in_development?
      :amazon_public_dev
    else
      :local
    end

  # Whether a blob's service answers a permanent public URL: R2Public does
  # (lib/active_storage/service/r2_public_service.rb), the private services and
  # Disk do not.
  def self.public_service?(service)
    service.public?
  end
end
