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

  test "a blob URL rendered in-request uses the request host, not the route-set default" do
    route_default = Rails.application.routes.default_url_options[:host]
    assert_not_equal ALIAS_HOST, route_default,
                     "this test is only meaningful when the request host differs from the default"

    host! ALIAS_HOST
    get contests_path

    assert_response :success
    src = css_select("img[src*='/rails/active_storage/blobs/redirect/']").first&.[]("src")
    assert src, "expected the contests page to render a contest banner blob URL"

    assert_equal ALIAS_HOST, URI.parse(src).host,
                 "an in-request blob URL must follow the host the visitor arrived on"
    assert_not_equal TurfMonster::HostConfig::PLACEHOLDER_HOST, URI.parse(src).host
  end
end
