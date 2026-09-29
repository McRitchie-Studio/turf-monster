# Site-wide singleton for link-preview (og:image) defaults.
#
# Mirrors SeasonConfig's singleton shape (one row, fetched via `.instance`,
# pinned to a hardcoded slug). Distinct from SeasonConfig — that's the on-chain
# Season pointer; this carries the marketing/unfurl defaults: the fallback
# og:image plus the default title/description used when a page doesn't set its
# own. Resolution + wiring into the layouts lives in OgHelper.
class SiteSetting < ApplicationRecord
  include Sluggable
  include OgImageAttachable

  # Public-read service so og:image resolves to a permanent absolute S3 URL.
  has_one_attached :default_og_image, service: OgImageAttachable::PUBLIC_OG_SERVICE

  OG_DEFAULTS_CACHE_KEY = "site_setting/og_defaults/v1".freeze

  # Admin edits are rare; the og defaults are read on EVERY page render. Bust the
  # cache on any change (callback covers title/description writes; the dashboard
  # controller busts explicitly after an image attach, which doesn't touch this row).
  after_commit { self.class.bust_og_defaults_cache! }

  # Cached resolution inputs for OgHelper — avoids a SiteSetting query (and a
  # blob lookup) on every layout render. `image_url` is the PERMANENT public URL
  # (prod S3) when present; Disk (dev/test) URLs are host-relative so we leave it
  # nil and resolve live. In test the cache is a null_store, so this is uncached
  # (block runs every call) — behaviour matches the pre-cache path.
  def self.og_defaults
    Rails.cache.fetch(OG_DEFAULTS_CACHE_KEY, expires_in: 1.hour) do
      s   = instance
      img = s.default_og_image
      {
        title:          s.default_og_title.presence,
        description:    s.default_og_description.presence,
        image_attached: img.attached?,
        image_url:      (img.attached? && OgImageAttachable.public_service?(img.blob.service) ? img.url : nil)
      }
    end
  end

  def self.bust_og_defaults_cache!
    Rails.cache.delete(OG_DEFAULTS_CACHE_KEY)
  end

  def self.instance
    # Runs on every page render (og:image defaults). find_or_create_by is a bare
    # SELECT once the row exists; the rescue only fires on the cold-start race —
    # two concurrent first requests both INSERT and the unique slug index makes
    # the loser raise RecordNotUnique (which would otherwise 500 a public page).
    find_or_create_by(slug: "site-setting")
  rescue ActiveRecord::RecordNotUnique
    find_by!(slug: "site-setting")
  end

  private

  def name_slug
    "site-setting"
  end
end
