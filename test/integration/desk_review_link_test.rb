require "test_helper"

# [integration] The review link bin/review-link hands over, end to end.
#
# The desk failure this guards is in test/controllers/studio/desk_link_db_binding_test.rb:
# a link minted out of band lands in whichever database the console happened to
# connect to, and the desk server — reading its own — bounces the operator to
# /signin. The cure is not a better console incantation. It is to mint
# IN-REQUEST, on the server that will serve the click, so the row cannot land
# anywhere else.
#
# /_studio/local_review is that mint, and bin/review-link is the one-line
# wrapper that prints its URL. These tests pin the two properties the handoff
# standard leans on, because a wrapper cannot be more correct than the endpoint
# underneath it:
#
#   1. The mint round-trips through THIS app's own store — the token it makes is
#      one this app can then resolve and sign in.
#   2. It is REUSABLE. Each click mints a fresh single-use token, so checking
#      the link does not spend it. That matters more than it sounds: a
#      hand-minted /l/<token> is single-use, so "let me just make sure it works"
#      burns it, and the operator gets the failure the checker just proved away.
#
# Scope note: the endpoint ships in studio-engine (>= 0.36, pinned here at
# 0.74.4). These assert TURF's wiring of it — that this app draws the route,
# provisions an admin who can actually reach an admin page, and completes the
# click — not the engine's internals, which the engine tests itself.
class DeskReviewLinkTest < ActionDispatch::IntegrationTest
  REVIEW_PATH = "/admin/entry_gifts".freeze

  test "the review mint lands in this app's own store and signs the reviewer in" do
    before = Studio::Link.magic_links.count

    get studio_local_review_path(return_to: REVIEW_PATH)

    assert_response :redirect
    assert_equal before + 1, Studio::Link.magic_links.count,
                 "the mint happens in-request, so the row lands in the database serving the click"

    token = URI.parse(response.location).path.split("/").last
    link  = Studio::Link.find_by(token: token)
    refute_nil link, "the token the operator is about to click must be resolvable HERE"
    assert_equal REVIEW_PATH, link.return_to, "and it carries the page under review"

    post link_consume_path(token: token)

    refute_nil session[Studio.session_key], "one click signs him in"
    assert_equal REVIEW_PATH, URI.parse(response.location).path,
                 "and lands him on the page under review, not on a sign-in wall"
  end

  # Provisioning is why the sign-in is worth anything: the operator's address is
  # a production one a fresh desk database has never seen, so without it the
  # consume creates him at the default role and require_admin bounces him off
  # the very page he was sent to. The sign-in would still "succeed".
  test "the reviewer it signs in can actually reach the admin page" do
    get studio_local_review_path(return_to: REVIEW_PATH)
    post link_consume_path(token: URI.parse(response.location).path.split("/").last)

    follow_redirect!

    assert_response :success, "an admin-gated page must render, not redirect to /"
  end

  # Each click mints its own token, so verifying the link costs the operator
  # nothing. bin/review-link relies on this: it follows the mint once to prove
  # the round trip before printing anything.
  test "the link is reusable — checking it does not spend the operator's click" do
    get studio_local_review_path(return_to: REVIEW_PATH)
    first = URI.parse(response.location).path.split("/").last
    post link_consume_path(token: first) # the checker burns this one
    refute_nil Studio::Link.find_by(token: first).consumed_at, "the checked token is spent"

    reset!

    get studio_local_review_path(return_to: REVIEW_PATH)
    second = URI.parse(response.location).path.split("/").last

    refute_equal first, second, "the same URL mints a fresh token rather than replaying the spent one"
    post link_consume_path(token: second)

    refute_nil session[Studio.session_key],
               "so the operator's own click still signs him in after it was verified"
  end

  # The endpoint is a desk convenience, not a sign-in path: it mints for an
  # address it never authenticates. Loopback is the only thing standing between
  # that and the open network, so pin it here rather than trusting the comment.
  test "a non-loopback request gets nothing" do
    get studio_local_review_path(return_to: REVIEW_PATH), headers: { "REMOTE_ADDR" => "203.0.113.7" }

    assert_response :not_found
    assert_nil session[Studio.session_key]
  end
end
