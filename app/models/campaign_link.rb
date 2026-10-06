# A short, human-named link for a marketing placement: turfmonster.media/l/tt
# instead of turfmonster.media/turf-monster-v2?reference=tiktok-bio in a bio.
#
#   GET /l/<token>  → 302 to target_path with ?r=<reference> appended
#
# WHY THIS IS A Studio::Link AND NOT A NEW TABLE. /l/<token> is already the one
# short-link door (Studio::LinksController), and studio_links already holds
# reusable, non-expiring, attribution-carrying links: the `referral` kind. A
# campaign link is a referral link that credits a NAMED placement instead of an
# inviting user, so it is stored as one: kind "referral", no linkable owner,
# and `metadata` = { "campaign" => true, "target" => path, "reference" => name }.
# That needs no engine release (Studio::LinkToken::KINDS is the engine's, and
# adding a kind there means a gem publish before this app can save a row), and
# it cannot collide with a user's referral link: Studio::Link.referral_for only
# ever reads rows whose linkable is the user.
#
# TOKENS ARE CHOSEN BY A PERSON, so they are validated where random ones are
# not (see the constants below). They share the studio_links unique index with
# every magic-link and referral token, which settles a clash either way: a
# random mint that lands on a campaign token retries (Studio::Link.mint!).
#
# PRECEDENCE AT /l/<token>: a campaign token is resolved FIRST, before the
# magic-link lookup and before the legacy /l/<slug> → /lp/<slug> fallback. A
# campaign can therefore shadow an old landing-page link, which is why one
# cannot be CREATED on a landing page's slug; the precedence only matters for a
# landing page made later with the same slug, and then the campaign the
# operator is actively sharing keeps working.
#
# DISABLING sets expires_at (the column every Studio::Link already honours);
# a disabled link sends a click to the home page with no reference. Links are
# never deleted from the admin: one printed in a bio or on a flyer keeps being
# clicked after anyone remembers it.
class CampaignLink < Studio::Link
  # 2-32 characters of lowercase letters, digits and inner hyphens. Lowercase
  # because a person types it off a screen; /l/TT still finds "tt" (see
  # .resolve). Random tokens are 16 mixed-case characters, so the two shapes
  # rarely overlap, and the unique index covers the case where they do.
  TOKEN_FORMAT = /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/
  TOKEN_LENGTH = (2..32)

  # "new" and "edit" are the admin's own routes (/admin/short_links/new would
  # never reach a link named "new"). The rest would read as a system path in a
  # bio, so a person cannot tell a campaign from the app.
  RESERVED_TOKENS = %w[
    new edit admin api app l lp i r login logout signin signup magic_link
    account settings help support
  ].freeze

  TARGET_LIMIT = 512
  # Keys this link's own reference replaces on the target, so the link's name
  # is the one counted even when the target path already carried one.
  ATTRIBUTION_KEYS = ReferralVisit::ATTRIBUTION_PARAMS

  default_scope { where(kind: "referral", linkable_id: nil).where("metadata @> ?", { campaign: true }.to_json) }

  scope :newest_first, -> { order(created_at: :desc) }

  after_initialize :mark_as_campaign, if: :new_record?
  before_validation :normalize_fields

  validates :token, length: { in: TOKEN_LENGTH }, format: { with: TOKEN_FORMAT, message: "may use only lowercase letters, digits and inner hyphens" }
  validate :token_not_reserved
  validate :token_not_a_landing_page, if: :will_save_change_to_token?
  validate :target_path_is_a_local_page
  validate :reference_present

  # The live-or-disabled campaign named by a /l/ token, or nil. Exact first,
  # then lowercased, so /l/TT finds "tt".
  def self.resolve(token)
    raw = token.to_s
    return nil if raw.blank?

    find_by(token: [raw, raw.downcase].uniq)
  end

  # --- metadata ---------------------------------------------------------------

  def target_path
    metadata["target"]
  end

  def target_path=(value)
    self.metadata = metadata.merge("target" => value.to_s.strip)
  end

  def reference
    metadata["reference"]
  end

  def reference=(value)
    self.metadata = metadata.merge("reference" => ReferralVisit.normalize_reference(value))
  end

  # --- status -----------------------------------------------------------------

  def active?
    live?
  end

  def disable!
    update!(expires_at: Time.current)
  end

  def enable!
    update!(expires_at: nil)
  end

  # --- resolution -------------------------------------------------------------

  # Where a click goes: the target with ?r=<reference> appended. The target's
  # own query string and fragment survive, as does `extra` (the query the
  # short link itself carried, e.g. utm_*), except any r/reference in either:
  # this link's reference is the one that counts.
  def destination(extra = {})
    uri = URI.parse(target_path)
    pairs = URI.decode_www_form(uri.query.to_s) + extra.to_h.map { |k, v| [k.to_s, v.to_s] }
    pairs.reject! { |key, _| ATTRIBUTION_KEYS.include?(key) }
    pairs << ["r", reference]
    uri.query = URI.encode_www_form(pairs)
    uri.to_s
  end

  def to_param
    token
  end

  private

  def mark_as_campaign
    self.kind = "referral"
    self.metadata = (metadata || {}).merge("campaign" => true)
  end

  def normalize_fields
    self.token = token.to_s.strip.downcase.presence
  end

  def token_not_reserved
    errors.add(:token, "is reserved") if RESERVED_TOKENS.include?(token)
  end

  # An old /l/<slug> link to a landing page must keep reaching it.
  def token_not_a_landing_page
    return if token.blank?

    errors.add(:token, "is a landing page's slug (/l/#{token} already reaches /lp/#{token})") if LandingPage.exists?(slug: token)
  end

  def target_path_is_a_local_page
    path = target_path.to_s
    if path.blank?
      errors.add(:target_path, "can't be blank")
    elsif !path.match?(%r{\A/(?![/\\])}) || !path.match?(/\A[[:graph:]]+\z/)
      errors.add(:target_path, "must be a path on this site, starting with a single /")
    elsif path.length > TARGET_LIMIT
      errors.add(:target_path, "is too long (#{TARGET_LIMIT} characters at most)")
    elsif path.match?(%r{\A/(l|i)(/|\z)})
      errors.add(:target_path, "can't be another short link")
    else
      URI.parse(path)
    end
  rescue URI::InvalidURIError
    errors.add(:target_path, "is not a valid path")
  end

  def reference_present
    errors.add(:reference, "can't be blank") if reference.blank?
  end
end
