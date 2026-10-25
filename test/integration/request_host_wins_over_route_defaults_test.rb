require "test_helper"

# THE SAFETY HALF of /tasks/blob-url-uses-example-org.
#
# The fix gives Rails.application.routes a default host so URL helpers have an
# answer OUTSIDE a request (config/initializers/route_default_url_options.rb).
# The obvious way for that fix to go wrong is for the default to also apply
# INSIDE a request, pinning every generated URL to one host regardless of which
# domain the visitor arrived on — turf-monster serves the canonical host plus
# APP_HOST_ALIASES, so that would be a real regression.
#
# It does not, because RouteSet#url_for merges the route-set defaults UNDER the
# options its caller passes, and a controller's url_options already carry
# request.host. This test pins that ordering against a host that is neither the
# route-set default nor the placeholder, so a future change that reverses the
# merge fails here rather than in production.
#
# WHICH URL IT READS. It read the lobby card's banner, a blob redirect URL, until
# the card moved to a host-relative proxy path to its :card variant
# (turf-every-visitor-lang-main-cache), which carries no host to get wrong. The
# lobby still renders an absolute, in-request Active Storage URL: its og:image,
# the featured contest's banner through the representation proxy route
# (OgHelper#contest_og_image_url). That URL MUST be absolute, since an unfurler
# has no page to resolve a relative one against, so it is the one that can pin
# the wrong host. The card is asserted host-relative too, so it cannot either.
class RequestHostWinsOverRouteDefaultsTest < ActionDispatch::IntegrationTest
  ALIAS_HOST = "app.turfmonster.test".freeze

  setup do
    @contest = contests(:one)
    @contest.contest_image.attach(
      io: File.open(Rails.root.join("test/fixtures/files/banner.png")),
      filename: "banner.png",
      content_type: "image/png"
    )
  end

  test "an Active Storage URL rendered in-request uses the request host, not the route-set default" do
    route_default = Rails.application.routes.default_url_options[:host]
    assert_not_equal ALIAS_HOST, route_default,
                     "this test is only meaningful when the request host differs from the default"

    host! ALIAS_HOST
    get contests_path

    assert_response :success
    src = css_select("meta[property='og:image'][content*='/rails/active_storage/representations/proxy/']")
          .first&.[]("content")
    assert src, "expected the contests page to render the featured banner as an absolute og:image URL"

    assert_equal ALIAS_HOST, URI.parse(src).host,
                 "an in-request Active Storage URL must follow the host the visitor arrived on"
    assert_not_equal TurfMonster::HostConfig::PLACEHOLDER_HOST, URI.parse(src).host

    card_src = css_select("[data-contest-card='#{@contest.slug}'] img.tt-contest-card-banner").first&.[]("src")
    assert card_src, "expected the contest card to render its banner"
    assert_nil URI.parse(card_src).host, "the card banner must be host-relative, so it pins no host at all"
    assert card_src.start_with?("/rails/active_storage/representations/proxy/"), card_src
  end
end
