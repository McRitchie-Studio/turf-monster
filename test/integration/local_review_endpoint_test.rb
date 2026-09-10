require "test_helper"

# [integration] studio-engine 0.19's dev-only mint endpoint, as TURF serves it.
#
# The board's WAITING APPROVAL button hands off to this endpoint on whatever
# local stack hosts the demo — and turf stacks host most of them. What is easy
# to get wrong here is the STORE/URL pairing: turf runs `magic_link_store =
# :database` (a Studio::Link row) but `draw_link_routes = false`, keeping its own
# /magic_link route (its /l namespace is the landing-page one). So the endpoint
# must hand out /magic_link/<token>, which is what turf's MagicLinksController
# (Studio::Link.consume!) actually reads. Handing out the engine default would
# yield "invalid or expired" on a link that was perfectly valid.
class LocalReviewEndpointTest < ActionDispatch::IntegrationTest
  test "mints a Studio::Link and hands out the URL TURF consumes it at" do
    assert_difference "Studio::Link.magic_links.count", 1 do
      get "/_studio/local_review", params: { email: users(:alex).email, return_to: "/contests" }
    end

    link = Studio::Link.magic_links.order(:created_at).last
    assert_equal users(:alex).email, link.email
    assert_equal "/contests", link.return_to, "the page under review must ride along"
    assert_redirected_to magic_link_url(token: link.token)
  end

  test "the URL it hands out actually signs the operator in" do
    # The property, not the shape: follow the endpoint's own output through
    # turf's consume and assert a session exists at the end.
    get "/_studio/local_review", params: { email: users(:alex).email, return_to: "/contests" }
    token = Studio::Link.magic_links.order(:created_at).last.token

    post magic_link_consume_path(token: token)

    assert_equal users(:alex).id, session[Studio.session_key],
      "the minted link must sign the operator in on THIS stack — that is the whole point"
  end

  test "a non-loopback request gets nothing" do
    # It hands out sign-in material without authenticating anyone, so loopback is
    # the floor (Studio.local_tool_enabled?).
    assert_no_difference "Studio::Link.count" do
      get "/_studio/local_review",
          params: { email: users(:alex).email, return_to: "/contests" },
          env: { "REMOTE_ADDR" => "203.0.113.7" }
    end

    assert_response :not_found
  end
end
