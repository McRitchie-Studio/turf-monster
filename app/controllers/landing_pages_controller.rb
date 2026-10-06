class LandingPagesController < ApplicationController
  skip_before_action :require_authentication
  skip_before_action :require_profile_completion, raise: false

  layout "landing"

  def show
    @landing_page = LandingPage.find_by(slug: params[:slug])

    unless viewable?(@landing_page)
      return redirect_to root_path, alert: "That landing page isn't available."
    end

    # First-touch attribution: tag the visitor with this funnel's slug so it
    # lands on the user at signup. An explicit ?reference= (captured by
    # ApplicationController#capture_reference) already in the cookie wins.
    cookies[:reference] = { value: @landing_page.slug, expires: 30.days } if cookies[:reference].blank?
    # A click on the page counts under its slug, unless the link named its own
    # reference (ReferralVisitTracking already counted that one).
    record_referral_visit(@landing_page.slug) if params[:reference].blank?

    @contest = @landing_page.contest
  end

  # GET /lp/:slug/claimed — where a CLAIM-MODE page's CTA ends: "You're in,
  # we'll email your free entry." The visitor must be signed in; a signed-out
  # one is sent to /signin carrying this path as return_to (and the page's
  # slug as ?reference=), and both sign-in paths bring them back here.
  #
  # It promises; it mints nothing. The operator hand-mints from
  # /admin/free_entries (Grant 1), which emails the player when the mint lands.
  def claimed
    @landing_page = LandingPage.find_by(slug: params[:slug])
    return redirect_to root_path unless viewable?(@landing_page)
    return redirect_to landing_page_path(@landing_page.slug) unless @landing_page.claim_mode?

    unless logged_in?
      return redirect_to signin_path(return_to: landing_page_claimed_path(@landing_page.slug),
                                     reference: @landing_page.slug)
    end

    attribute_claim_to_page!
    @contest = @landing_page.contest
    @claimant = current_user
  end

  # GET /tiktok (and every vanity slug config/routes.rb lists). A 302, never a 301:
  # the answer changes when the page is created or switched off, and a browser
  # that cached a permanent redirect would keep the old one.
  #
  # The query string rides along either way, so a ?reference= in the link still
  # wins first touch (ApplicationController#capture_reference runs first).
  #
  # No viewable page → the home page carrying ?reference=<slug>, NOT the /lp
  # "isn't available" bounce. Someone who typed the URL off a video still gets
  # attributed to the channel, and the funnel keeps working in the gap between
  # the video going up and the operator publishing the page.
  def vanity
    slug  = params[:slug]
    query = request.query_parameters
    # Counted here, on the spoken-aloud path, as well as on wherever it lands:
    # the second hop is the same visitor, reference and day, so it dedupes.
    record_referral_visit(slug) if params[:reference].blank?

    if viewable?(LandingPage.find_by(slug: slug))
      redirect_to landing_page_path(slug, query)
    else
      redirect_to root_path({ "reference" => slug }.merge(query))
    end
  end

  private

  # How recent an account must be for a claim to name this page as its signup
  # source. Signup already copies the reference cookie onto the user; this is
  # the backstop for the case it cannot see — a magic link opened in a
  # different browser (the phone's mail app) than the one that visited /tiktok,
  # which carries no cookie. An OLDER account with no source is not re-labelled:
  # it signed up some other way, and the filter on /admin/free_entries is a
  # record of where signups came from.
  CLAIM_ATTRIBUTION_WINDOW = 1.day

  def attribute_claim_to_page!
    user = current_user
    return if user.reference.present?
    return if user.created_at < CLAIM_ATTRIBUTION_WINDOW.ago

    user.update_column(:reference, @landing_page.slug)
  end

  # Inactive pages are visible to admins only (for preview before launch).
  def viewable?(page)
    page.present? && (page.active? || current_user&.admin?)
  end
end
