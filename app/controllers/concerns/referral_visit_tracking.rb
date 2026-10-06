# Counts clicks on trackable links, on every page: any GET that arrives with
# `?reference=<name>` records one ReferralVisit for this visitor, today. The
# landing page (/lp/:slug) and the vanity paths (/tiktok) record their own slug
# through #record_referral_visit when the link carried no explicit reference.
#
# PREPENDED, so it runs before every other before_action. A click on a link to
# a page that then redirects (to /signin, a profile step, an old-browser 406)
# was still a click, and a callback queued after those would never see it.
#
# The visitor is a random first-party cookie id, set only when a click is
# recorded, so a visitor who never followed a trackable link carries no
# cookie from this. It is what lets ReferralVisit dedupe a refresh.
#
# NEVER BREAKS A PAGE: every path through here rescues and continues.
# (`rescue_and_log` is not the tool for that; it re-raises.)
module ReferralVisitTracking
  extend ActiveSupport::Concern

  VISITOR_COOKIE = :referral_visitor
  VISITOR_ID_FORMAT = /\A[0-9a-f-]{36}\z/

  included do
    prepend_before_action :record_referral_visit_from_params
  end

  private

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

    ReferralVisit.record(
      reference: reference,
      visitor_id: referral_visitor_id,
      path: request.path,
      utm: request.query_parameters.slice(*ReferralVisit::UTM_KEYS)
    )
  rescue StandardError => e
    Rails.logger.warn("[referral_visit] tracking skipped #{e.class}: #{e.message}")
    false
  end

  def referral_visitor_id
    existing = cookies[VISITOR_COOKIE].to_s
    return existing if existing.match?(VISITOR_ID_FORMAT)

    SecureRandom.uuid.tap do |id|
      cookies[VISITOR_COOKIE] = { value: id, expires: 1.year, httponly: true, same_site: :lax }
    end
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
