# Counts clicks on trackable links, on every page: any GET that arrives with
# `?reference=<name>` records one ReferralVisit for this visitor, today. The
# landing page (/lp/:slug) and the vanity paths (/tiktok) record their own slug
# through #record_referral_visit when the link carried no explicit reference.
#
# PREPENDED, so it runs before every other before_action. A click on a link to
# a page that then redirects (to /signin, a profile step, an old-browser 406)
# was still a click, and a callback queued after those would never see it.
#
# A ROW NEEDS A VISITOR COOKIE THAT CAME BACK. The visitor is a random
# first-party cookie id, and it is what lets ReferralVisit dedupe a refresh. A
# client that never returns cookies (a script, most crawlers) would get a fresh
# id on every request and so a fresh row, without bound. So the first click
# from a browser without the cookie writes nothing: it sets the visitor cookie
# and parks the click in a signed PENDING_COOKIE. The browser's next request to
# this app (the vanity redirect's second hop, the sign-in bounce, the next page,
# a signup POST) carries both back, and that request records the parked click.
# A request carrying the visitor cookie records at once. The cost: a person who
# opens one page and leaves before any second request is not counted.
#
# Every write is also capped per client address
# (Rack::Attack.referral_visit_allowed?, config/initializers/rack_attack.rb),
# which bounds a client that makes up a new visitor cookie on each request.
#
# A visitor who never followed a trackable link carries no cookie from this.
#
# NEVER BREAKS A PAGE: every path through here rescues and continues, and
# records what it swallowed through ReferralVisit.report_failure (the Rails
# log and ErrorLog, itself never raising). (`rescue_and_log` is not the tool
# for that; it re-raises.)
module ReferralVisitTracking
  extend ActiveSupport::Concern

  VISITOR_COOKIE = :referral_visitor
  PENDING_COOKIE = :referral_pending
  PENDING_TTL = 1.hour
  VISITOR_ID_FORMAT = /\A[0-9a-f-]{36}\z/

  included do
    prepend_before_action :track_referral_visit
  end

  private

  def track_referral_visit
    record_pending_referral_visit
    record_referral_visit_from_params
  end

  def record_referral_visit_from_params
    return if params[:reference].blank?
    # Coinflow's checkout returns to /tokens/buy?coinflow=return&reference=<purchase
    # slug>: a payment reference, not a marketing one.
    return if params[:coinflow].present?

    record_referral_visit(params[:reference])
  end

  def record_referral_visit(reference)
    return false unless ReferralVisit.trackable_request?(
      method: request.request_method,
      path: request.path,
      user_agent: request.user_agent,
      html: referral_html_request?,
      xhr: request.xhr?,
      prefetch: referral_prefetch_request?
    )

    utm = request.query_parameters.slice(*ReferralVisit::UTM_KEYS)
    visitor_id = returned_referral_visitor_id
    return park_referral_visit(reference, request.path, utm) if visitor_id.nil?

    write_referral_visit(reference, visitor_id, request.path, utm)
  rescue StandardError => e
    ReferralVisit.report_failure(e, "tracking skipped")
    false
  end

  # The click parked by an earlier request, now that the visitor cookie has
  # come back with it. Any request method counts as the return: the click was
  # judged trackable when it was parked.
  def record_pending_referral_visit
    return if request.cookies[PENDING_COOKIE.to_s].blank?

    pending = parse_pending_referral_visit
    cookies.delete(PENDING_COOKIE)
    visitor_id = returned_referral_visitor_id
    return if pending.nil? || visitor_id.nil? || ReferralVisit.bot?(request.user_agent)

    write_referral_visit(pending["reference"], visitor_id, pending["path"], pending["utm"])
  rescue StandardError => e
    ReferralVisit.report_failure(e, "pending visit skipped")
    false
  end

  def write_referral_visit(reference, visitor_id, path, utm)
    return false unless Rack::Attack.referral_visit_allowed?(request)

    ReferralVisit.record(reference: reference, visitor_id: visitor_id, path: path, utm: utm.to_h)
  end

  # Sets the visitor cookie and parks the click until it comes back.
  def park_referral_visit(reference, path, utm)
    pending = { reference: reference.to_s.first(ReferralVisit::REFERENCE_LIMIT),
                path: path.to_s.first(ReferralVisit::PATH_LIMIT),
                utm: utm.to_h.transform_values { |v| v.is_a?(String) ? v.first(ReferralVisit::UTM_LIMIT) : nil } }
    cookies.signed[PENDING_COOKIE] = { value: pending.to_json, expires: PENDING_TTL, httponly: true, same_site: :lax }
    set_referral_visitor_cookie
    false
  end

  def parse_pending_referral_visit
    raw = cookies.signed[PENDING_COOKIE]
    parsed = raw.is_a?(String) ? JSON.parse(raw) : nil
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError
    nil
  end

  # The visitor id the browser SENT, never one this request set: only a cookie
  # that made the round trip proves the client keeps cookies.
  def returned_referral_visitor_id
    sent = request.cookies[VISITOR_COOKIE.to_s].to_s
    sent.match?(VISITOR_ID_FORMAT) ? sent : nil
  end

  def set_referral_visitor_cookie
    return if cookies[VISITOR_COOKIE].to_s.match?(VISITOR_ID_FORMAT)

    cookies[VISITOR_COOKIE] = { value: SecureRandom.uuid, expires: 1.year, httponly: true, same_site: :lax }
  end

  # A browser that sends its usual Accept list resolves to html; an in-app
  # webview that sends a bare */* is still a person opening a page.
  def referral_html_request?
    format = request.format
    format.html? || format.to_s == "*/*"
  end

  def referral_prefetch_request?
    [request.headers["Sec-Purpose"], request.headers["Purpose"], request.headers["X-Sec-Purpose"],
     request.headers["X-Moz"]].any? { |value| value.to_s.downcase.include?("prefetch") }
  end
end
