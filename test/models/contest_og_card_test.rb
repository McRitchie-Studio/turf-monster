# frozen_string_literal: true

require "test_helper"
require "mini_magick"

# [unit] The link-preview rendition of a contest banner — Contest's :og_card
# variant, which is what a shared contest URL unfurls with.
#
# WHY A VARIANT AND NOT THE BANNER ITSELF. The admin uploader crops banners 5:1
# (imageUploadHost aspectRatio: 5) because a banner is a wide strip above a
# contest. Every unfurler renders og:image at roughly 1.91:1, so the raw strip
# arrives as a sliver. This asserts the composite that reconciles the two — the
# banner scaled to fit and centred on the brand navy at exactly 1200x630.
#
# THE TRANSPARENCY CASE IS THE ONE THAT ROTS SILENTLY. The uploader allows a
# transparent banner (`transparent: true`), and a card that keeps that alpha
# lands its subject on whatever each client composites against — white in one
# chat app, black in the next.
#
# WHAT FLATTENS IT IS `background:`, THE SAME OPTION THAT PAINTS THE BARS —
# there is no separate alpha-flattening operation in the variant, and this file
# must not send anyone looking for one. image_processing's MiniMagick
# resize_and_pad (mini_magick.rb:90-95) expands to
# `-resize … -background … -gravity … -extent …`, and -extent composites the
# scaled banner ONTO that background canvas. Drop `background:` and it defaults
# to :transparent, so the flattening goes with it. Adding an `alpha: "remove"`
# INSIDE resize_and_pad does not help either — it is forwarded to the gem's
# `thumbnail` helper (which emits -resize, despite the name),
# which has no such keyword, and raises ArgumentError.
#
# Measured 2026-09-09 by mutation: with `background:` removed from the variant,
# the opacity assertion at :69 fails AND the navy-bar assertion at :44 fails.
# Both bite, and they bite on the same option.
class ContestOgCardTest < ActiveSupport::TestCase
  BRAND_NAVY   = "srgb(30,27,53)"   # Contest::OG_CARD_BACKGROUND (#1E1B35)
  FIXTURE_GREEN = "srgb(34,197,94)" # the opaque third of banner_transparent.png

  # Renders the card the same way the proxy route does and reads it back with
  # the same ImageMagick that produced it.
  def card_for(fixture)
    contest = contests(:one)
    contest.contest_image.attach(
      io: file_fixture(fixture).open, filename: fixture, content_type: "image/png"
    )
    variant = contest.contest_image.variant(:og_card).processed
    blob    = variant.respond_to?(:image) ? variant.image.blob : variant.blob
    MiniMagick::Image.read(blob.download)
  end

  test "og_card pads a wide banner into the 1200x630 unfurl card" do
    card = card_for("banner_wide.png")

    assert_equal Contest::OG_CARD_SIZE, [card.width, card.height]
    # The band above the banner is the brand navy the pad painted...
    assert_equal BRAND_NAVY, card["%[pixel:p{2,2}]"]
    # ...and the middle is still the banner, not more padding.
    assert_not_equal BRAND_NAVY, card["%[pixel:p{600,315}]"],
                     "the banner itself should occupy the centre band of the card"
  end

  test "og_card renders a png the unfurlers can read" do
    card = card_for("banner_wide.png")

    assert_equal "PNG", card.type
  end

  # --- the alpha regression ---

  test "og_card flattens a transparent banner onto the brand navy" do
    # banner_transparent.png is 1000x200: an opaque #22C55E block across the
    # left 300px, the remaining 700px fully transparent. Scaled to fit 1200x630
    # it becomes 1200x240 centred at y 195..434, so x=800 y=315 lands inside
    # what was transparent and x=100 y=315 inside what was not.
    card = card_for("banner_transparent.png")

    # DOWNCASED ON PURPOSE: ImageMagick 7 (the dev Macs and the Heroku dynos)
    # prints "True" for %[opaque] while ImageMagick 6 (the ubuntu-24.04 runner's
    # `imagemagick` package, via convert-im6.q16) prints "true". The casing is
    # the version talking, not the image.
    assert_equal "true", card["%[opaque]"].to_s.downcase,
                 "a transparent banner must be flattened, or the subject renders on the client's own background"
    assert_equal BRAND_NAVY, card["%[pixel:p{800,315}]"],
                 "transparent banner pixels must land on the brand navy, not stay transparent"
    assert_equal FIXTURE_GREEN, card["%[pixel:p{100,315}]"],
                 "flattening must not disturb the banner's own opaque pixels"
  end
end
