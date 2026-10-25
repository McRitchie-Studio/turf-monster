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
# The URL is the contract: a variant is served from
# /rails/active_storage/representations/…, the original from …/blobs/…. Both
# halves are asserted, because a card that rendered both would pass either alone.
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

  test "[unit] the contest card renders a representation URL, never the raw blob URL" do
    log_in_as(users(:alex))
    get contests_path

    assert_response :success
    banners = css_select("[data-contest-card='#{@contest.slug}'] img.tt-contest-card-banner")
    assert_equal 1, banners.size, "the card must render its banner image"
    src = banners.first["src"]
    assert_match %r{/rails/active_storage/representations/}, src
    assert_no_match %r{/rails/active_storage/blobs/}, src
  end
end
