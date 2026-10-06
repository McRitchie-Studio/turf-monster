# One click on a trackable link: a visitor who arrived carrying a reference
# (`?reference=tiktok-bio`, a /lp/<slug> landing page, or a vanity path like
# /tiktok), counted once per visitor per reference per day.
#
# WHY A ROW PER VISITOR-DAY AND NOT A ROW PER REQUEST. The question this table
# answers is "how many people clicked my TikTok link", and a refresh, a back
# button, or the vanity redirect's second hop must not each count as a click.
# The unique index on (reference, visitor_id, visited_on) is the dedupe, and
# `.record` is a single INSERT ... ON CONFLICT DO NOTHING, so the count holds
# under concurrent requests without a read first.
#
# NEVER BREAKS A PAGE. `.record` is called from a before_action on every page
# (ReferralVisitTracking), so it rescues every error, records it
# (.report_failure: the Rails log and ErrorLog), and returns false. A click
# lost to a database hiccup costs a count; a raise here would
# cost the visitor the page.
#
# References are normalized (stripped, downcased, first 64 characters) so
# "TikTok" and "tiktok" land in one row. users.reference keeps the raw cookie
# value, so ReferralReport groups that column by LOWER(TRIM(...)) to match.
class ReferralVisit < ApplicationRecord
  REFERENCE_LIMIT = 64
  PATH_LIMIT = 255
  UTM_LIMIT = 100
  UTM_KEYS = %w[utm_source utm_medium utm_campaign].freeze

  # How long a row is kept. ReferralVisitPruneJob deletes rows whose
  # visited_on is older, nightly, so the table holds at most this many days of
  # clicks and the report's "all time" window means "the last RETENTION".
  RETENTION = 400.days

  # Paths whose requests are never a click on a public link: operator pages,
  # machine endpoints, and asset or socket traffic. The second line is every
  # path that carries a bearer token (/l/:token, /i/:token, /magic_link/:token,
  # /email_verification/:token, and the /account/ token pages): landing_path
  # stores request.path, so a link to one of these carrying ?reference= would
  # otherwise file the token into this table and the admin report.
  SKIPPED_PATH_PREFIXES = %w[
    /admin /api /rails/ /assets/ /cable /_studio /up /webhooks /auth/ /test/
    /l/ /i/ /magic_link/ /email_verification/ /account/
  ].freeze

  # Crawlers, link unfurlers and scripted clients. Studio::LinkPreview.bot?
  # already knows the preview fetchers (facebookexternalhit, Twitterbot,
  # Slackbot-LinkExpanding, Discordbot, ...); this adds the generic crawler
  # spellings and TikTok's own fetchers (Bytespider, TikTokBot), which carry
  # "spider"/"bot". TikTok's IN-APP BROWSER is a person and matches none of
  # these: its UA is a normal mobile WebKit string plus "musical_ly" and
  # "BytedanceWebview".
  CRAWLER_PATTERN = /bot\b|bot\/|crawl|spider|slurp|preview|fetcher|headless|
                     lighthouse|curl\/|wget\/|python-requests|python-urllib|
                     go-http-client|okhttp|axios\/|node-fetch|httpclient/ix

  scope :since, ->(date) { date ? where(visited_on: date..) : all }

  # "  TikTok " -> "tiktok". nil for a blank value.
  def self.normalize_reference(raw)
    raw.to_s.strip.downcase.first(REFERENCE_LIMIT).presence
  end

  def self.bot?(user_agent)
    ua = user_agent.to_s
    return true if ua.strip.empty?

    Studio::LinkPreview.bot?(ua) || CRAWLER_PATTERN.match?(ua)
  end

  # Whether this request is one a person makes by following a link. Only a
  # GET for an HTML page counts: HEAD is a link checker, XHR/JSON is the app
  # talking to itself, and a Turbo prefetch is a hover, not a click.
  def self.trackable_request?(method:, path:, user_agent:, html:, xhr: false, prefetch: false)
    return false unless method.to_s.upcase == "GET"
    return false unless html
    return false if xhr || prefetch
    return false if skipped_path?(path)

    !bot?(user_agent)
  end

  # A prefix ending in "/" covers only what is under it, so "/account/" skips
  # /account/wallet/export/<token> and keeps /account; one without covers the
  # path itself too ("/admin" skips /admin and /admin/referrals).
  def self.skipped_path?(path)
    p = path.to_s
    SKIPPED_PATH_PREFIXES.any? do |prefix|
      prefix.end_with?("/") ? p.start_with?(prefix) : (p == prefix || p.start_with?("#{prefix}/"))
    end
  end

  # Deletes every row whose day is older than RETENTION. Returns the count.
  def self.prune(today: Date.current)
    where(visited_on: ...(today - RETENTION)).delete_all
  end

  # Records one click. Returns true when the call reached the database (a
  # duplicate is answered with true too: the visit is already counted), false
  # when there was nothing to record or the write failed.
  def self.record(reference:, visitor_id:, path:, utm: {}, at: Time.current)
    ref = normalize_reference(reference)
    return false if ref.nil? || visitor_id.blank?

    insert(
      {
        reference: ref,
        visitor_id: visitor_id.to_s.first(36),
        visited_on: at.to_date,
        landing_path: path.to_s.first(PATH_LIMIT).presence,
        utm_source: utm_value(utm, "utm_source"),
        utm_medium: utm_value(utm, "utm_medium"),
        utm_campaign: utm_value(utm, "utm_campaign"),
        first_seen_at: at
      },
      unique_by: :index_referral_visits_on_ref_visitor_day
    )
    true
  rescue StandardError => e
    report_failure(e, "not recorded ref=#{ref.inspect}")
    false
  end

  # A swallowed tracking failure, recorded where the operator triages errors
  # (ErrorLog, /admin/error_logs, which fans out to Sentry) as well as the
  # Rails log. NEVER RAISES: it runs inside the rescue of a before_action on
  # every page, and the failure it reports is often the database, which is
  # where ErrorLog writes too. A capture that fails is logged and dropped.
  # (`rescue_and_log` is not the tool here; it re-raises.)
  def self.report_failure(error, context)
    Rails.logger.warn("[referral_visit] #{context} #{error.class}: #{error.message}")
    ErrorLog.capture!(error)
    nil
  rescue StandardError => capture_error
    Rails.logger.error("[referral_visit] ErrorLog capture failed #{capture_error.class}: #{capture_error.message}")
    nil
  end

  def self.utm_value(utm, key)
    value = utm.to_h.stringify_keys[key]
    value.is_a?(String) ? value.strip.downcase.first(UTM_LIMIT).presence : nil
  end
  private_class_method :utm_value
end
