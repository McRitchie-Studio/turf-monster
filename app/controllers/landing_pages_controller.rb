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

    @contest = @landing_page.contest
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

    if viewable?(LandingPage.find_by(slug: slug))
      redirect_to landing_page_path(slug, query)
    else
      redirect_to root_path({ "reference" => slug }.merge(query))
    end
  end

  private

  # Inactive pages are visible to admins only (for preview before launch).
  def viewable?(page)
    page.present? && (page.active? || current_user&.admin?)
  end
end
