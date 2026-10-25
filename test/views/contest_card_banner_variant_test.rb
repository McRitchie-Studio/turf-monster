# frozen_string_literal: true

require "test_helper"

# [unit] THE LOBBY CARD SERVES A RESIZED BANNER, NEVER THE UPLOAD
# (task: turf-every-visitor-lang-main-cache; audit 2026-10-24, lane UI P3).
#
# `image_tag contest.contest_image` linked the original blob: a 1.3 MB banner.png
# into a 384x144 box, measured on /contests. The card now renders the `:card`
# variant, sized to 2x the largest box it is drawn in (sm:w-96 h-36 = 384x144,
# so 768x288; the box is w-80, 320 wide, below sm).
#
# The URL is the contract: the variant through the PROXY route,
# /rails/active_storage/representations/proxy/…, the original from …/blobs/….
# Proxy, not redirect (docs/UI_PATTERNS.md, "Renditions of an image that lives
# on the PRIVATE service"): the redirect route answers with a 302 to a
# five-minute signed bucket URL the browser cannot cache, the proxy streams it
# from our own domain. Both halves are asserted, because a card that rendered
# both would pass either alone.
# No image backend runs here: building a representation URL does not process it.
class ContestCardBannerVariantTest < ActionDispatch::IntegrationTest
  setup do
    SeasonConfig.set_current!(1)
    @contest = contests(:one)
    @contest.contest_image.attach(
      io: File.open(Rails.root.join("test/fixtures/files/banner.png")),
      filename: "banner.png", content_type: "image/png"
    )
  end

  test "[unit] the :card variant fills 2x the card banner's largest box" do
    variant = Contest.reflect_on_attachment(:contest_image).named_variants[:card]

    assert_not_nil variant, "Contest#contest_image must declare a :card variant"
    assert_equal({ resize_to_fill: [768, 288] }, variant.transformations)
  end

  test "[unit] the contest card renders a proxied representation URL, never the raw blob URL" do
    log_in_as(users(:alex))
    get contests_path

    assert_response :success
    banners = css_select("[data-contest-card='#{@contest.slug}'] img.tt-contest-card-banner")
    assert_equal 1, banners.size, "the card must render its banner image"
    src = banners.first["src"]
    assert_match %r{/rails/active_storage/representations/proxy/}, src
    assert_no_match %r{/rails/active_storage/blobs/}, src
  end

  test "[unit] a banner Active Storage cannot vary falls back to the gradient, not a 500" do
    @contest.contest_image.blob.update!(content_type: "image/svg+xml")
    log_in_as(users(:alex))
    get contests_path

    assert_response :success
    assert_select "[data-contest-card='#{@contest.slug}'] img.tt-contest-card-banner", count: 0
    assert_select "[data-contest-card='#{@contest.slug}'] div.tt-contest-card-banner", count: 1
  end
end
