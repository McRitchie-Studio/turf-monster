# frozen_string_literal: true

require "test_helper"

# [component] layouts/_link_preview_meta — the partial both layouts render to
# emit a page's unfurl card.
#
# WHY THIS PARTIAL IS WORTH ITS OWN TEST. It is the single seam every
# link-preview feature ends at: the site default, a funnel page's override, and
# a contest's banner card all resolve elsewhere and then arrive HERE as one
# `image` local. A change to the partial breaks all three at once, and it breaks
# them where nothing else looks — in markup no page renders visibly.
#
# TWITTER:IMAGE IS THE HALF THAT GOES MISSING. og:image and twitter:image are
# separate tags carrying the same URL; X reads the twitter: one and falls back
# to og: only for tags it has no twin for. A partial that set og:image alone
# would look correct in Discord and iMessage — the clients anyone tests with —
# and quietly ship a card-less link on X.
class LinkPreviewCardTest < ActionView::TestCase
  CARD = "http://test.host/rails/active_storage/representations/proxy/abc/def/og-card.png"

  def render_card(image:, image_default:)
    render partial: "layouts/link_preview_meta",
           locals: { title: "A Title", description: "A description.",
                     image: image, image_default: image_default }
  end

  test "an uploaded card is emitted for both og:image and twitter:image" do
    render_card(image: CARD, image_default: false)

    assert_select "meta[property='og:image'][content=?]", CARD
    assert_select "meta[name='twitter:image'][content=?]", CARD
    assert_select "meta[name='twitter:card'][content='summary_large_image']"
  end

  test "an uploaded card claims no dimensions" do
    render_card(image: CARD, image_default: false)

    # The fixed 1200x630 tags describe the static og.png ONLY. Emitting them for
    # an upload of unknown size tells the client to lay out a box the image does
    # not fill — a contest banner card is padded to 1200x630 by the variant, but
    # a funnel page's own upload can be any shape.
    assert_select "meta[property='og:image:width']", count: 0
    assert_select "meta[property='og:image:height']", count: 0
  end

  test "the static default still declares its known dimensions" do
    render_card(image: "http://test.host/og.png", image_default: true)

    assert_select "meta[property='og:image:width'][content='1200']"
    assert_select "meta[property='og:image:height'][content='630']"
    assert_select "meta[property='og:image:type'][content='image/png']"
  end
end
