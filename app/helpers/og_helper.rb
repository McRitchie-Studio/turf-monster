# Resolves link-preview (og/twitter) metadata for the layouts.
#
# Resolution order (most specific wins, static asset is the ultimate fallback
# so a preview NEVER breaks even with nothing uploaded):
#
#   image: contest.contest_image  ->  landing_page.og_image
#          ->  SiteSetting default_og_image  ->  /og.png
#   title: content_for(:title)    ->  SiteSetting default_og_title  ->  hardcoded
#   desc:  content_for(:meta_..)  ->  SiteSetting default_og_desc.   ->  hardcoded
#
# A contest page sets its own :title and :meta_description from
# contest_og_title / contest_og_description, so it previews with its name
# rather than the site-wide copy.
#
# `landing_page` is nil on the standard application layout; the landing layout
# passes the current @landing_page so an operator can override per funnel page.
# The contest rung is not a fourth argument to og_image_url — a contest page
# rides the plain application layout, so contests/show sets the resolved URL as
# `content_for :og_image` and the layout's page-level override picks it up.
module OgHelper
  # Fallbacks baked into the layouts before this helper existed; kept here as
  # the last resort when SiteSetting has no admin-set default. Skill-contest
  # framing first (underwriting compliance) — blockchain transparency is the
  # secondary note, with /transparency as the deep-dive hub. Sport-generic on
  # purpose: this is the site-wide default, so it names no league and covers
  # contests and head-to-head play alike. A contest page supplies its own copy.
  DEFAULT_OG_TITLE = "Turf Monster — Skill-Based Pick’em Contests".freeze
  DEFAULT_OG_DESCRIPTION =
    "Turf Monster: skill-based pick’em. Pick your teams, stack Turf Scores, and win cash " \
    "prizes in contests or head-to-head against friends, with transparent, verifiable payouts.".freeze

  def og_image_url(landing_page = nil)
    # Per-funnel override wins (queries the landing page's attachment).
    lp_image = landing_page&.og_image
    return absolute_og_url(lp_image) if lp_image&.attached?

    defaults = SiteSetting.og_defaults
    # Prod: cached permanent public URL — no query. Dev/test (Disk): the cached
    # URL is nil, so resolve the attachment live.
    return defaults[:image_url] if defaults[:image_url]
    return absolute_og_url(SiteSetting.instance.default_og_image) if defaults[:image_attached]

    "#{request.base_url}/og.png"
  end

  # True when neither a landing-page nor a site-default image is attached — the
  # layout uses this to decide whether to emit the fixed 1200x630 dimensions
  # (only valid for the static og.png; uploads may be any size).
  def og_image_default?(landing_page = nil)
    !(landing_page&.og_image&.attached? || SiteSetting.og_defaults[:image_attached])
  end

  # The contest's own banner, composed into the 1200x630 link-preview card
  # (Contest's :og_card variant). nil when the contest has no banner, so the
  # layout's `content_for(:og_image).presence` falls through to the site default
  # exactly as an unbannered page always has.
  #
  # PROXY, NOT `.url`. contest_image lives on the PRIVATE service, whose `.url`
  # is a signature that expires — and an unfurler caches the og:image URL it was
  # given and re-fetches it days later, so an expiring URL is a preview that
  # works today and is broken by the weekend. The proxy route is a permanent URL
  # on our own domain (the signed blob id carries no expiry) and streams from
  # the same private bucket, so nothing has to move to public storage.
  def contest_og_image_url(contest)
    return nil unless contest&.contest_image&.attached?
    return nil unless contest.contest_image.variable?

    rails_storage_proxy_url(contest.contest_image.variant(:og_card))
  end

  # Everything the page's identity tags need, resolved in one place and
  # shared by the full application layout and the slim link-preview document
  # (layouts/_page_identity), so the two never disagree. Reads the page's
  # content_for overrides, which the view has set by the time the layout runs.
  def page_link_preview
    image_override = content_for(:og_image).presence
    {
      title: og_title(content_for(:title)),
      description: og_description(content_for(:meta_description)),
      image: image_override || og_image_url,
      image_default: image_override.blank? && og_image_default?
    }
  end

  # A contest page's own preview title, instead of the site-wide default.
  def contest_og_title(contest)
    "#{contest.name} — Turf Monster"
  end

  # A contest page's own preview description: its tagline (or name), the money
  # line a player decides on, then the one-line pitch.
  def contest_og_description(contest)
    lead = contest.tagline.presence || contest.name
    prize = contest.guaranteed_prize_dollars.to_i
    fee = contest.entry_fee_dollars.to_i
    money = []
    money << "$#{prize} in prizes" if prize.positive?
    money << (fee.positive? ? "$#{fee} entry" : "free to enter")
    "#{lead}: #{money.join(', ')}. Skill-based pick’em on Turf Monster: " \
      "pick your matchups, stack Turf Scores, and win cash prizes."
  end

  def og_title(override = nil)
    override.presence || SiteSetting.og_defaults[:title] || DEFAULT_OG_TITLE
  end

  def og_description(override = nil)
    override.presence || SiteSetting.og_defaults[:description] || DEFAULT_OG_DESCRIPTION
  end

  private

  # Public S3 (prod) returns a permanent absolute URL directly — exactly what an
  # unfurler needs. Disk (dev/test) has no public URL, and `attachment.url` there
  # raises without ActiveStorage::Current.url_options (unset in integration
  # tests), so build an absolute URL from a host-relative blob path instead — no
  # Current dependency, still ends with the filename.
  def absolute_og_url(attachment)
    if OgImageAttachable.public_service?(attachment.blob.service)
      attachment.url
    else
      "#{request.base_url}#{rails_blob_path(attachment)}"
    end
  end
end
