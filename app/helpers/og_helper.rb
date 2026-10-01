# The contest page's own link preview: its banner as the card image, and its
# name and money line as the words. contests/show sets them as
# content_for(:og_image), content_for(:title) and content_for(:meta_description),
# which studio-engine's link preview reads beneath a page's `link_preview` call
# (docs/LINK_PREVIEW.md in the gem).
#
# Everything else this helper used to do (resolving the site-wide default
# image, title and description from SiteSetting, and the hardcoded fallbacks)
# moved to the engine: the default lives in Studio::SiteIdentity, edited at
# /admin/link_preview, and the drafted copy in config/initializers/studio.rb.
# /tasks/turf-adopts-link-preview.
module OgHelper
  # The contest's own banner, composed into the 1200x630 link-preview card
  # (Contest's :og_card variant). nil when the contest has no banner, so the
  # engine's resolution falls through to the site identity's image (then the
  # static /og.png) exactly as an unbannered page always has.
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
end
