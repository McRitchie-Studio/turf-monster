require "test_helper"

# Clicking a magic link a SECOND time must not cost you your session.
#
# Before this app adopted Studio::LinkConsumption, every consume ran
# reset_prior_session! and every failure redirected to /signin — so a visitor
# who clicked their own link twice was thrown out of a session that was
# perfectly valid, and told "that sign-in link is invalid or has expired" about
# a link they had just used successfully.
#
# The rules, from studio-engine's Studio::LinkResolution:
#
#                | nobody signed in | the link's own user | somebody else
#   -------------+------------------+---------------------+-----------------
#   live         | sign in / sign up| burn, keep session  | switch identity
#   used/expired | /signin + reason | silent redirect     | keep session, say so
#   unknown      | /signin + reason | —                   | keep session, say so
#
# The invariant underneath all of it: a DEAD link never touches the session.
#
# Turf-specific and load-bearing: the message rides in flash[:auth_toast].
# This app renders auth_toast and magic_link_welcome and NOTHING ELSE — plain
# flash[:notice] / flash[:alert] appear in no layout or view — so a message
# delivered the engine's default way would be invisible. These assert the toast,
# because that is what a person actually sees.
class MagicLinkReclickTest < ActionDispatch::IntegrationTest
  setup    { ENV["ENABLE_AGE_ATTESTATION"] = "true" }
  teardown { ENV.delete("ENABLE_AGE_ATTESTATION") }

  # --- the reported bug -------------------------------------------------------

  test "clicking your own link a second time keeps you signed in" do
    user  = users(:alex)
    token = magic_token(email: user.email, age_attested: true)

    post link_consume_path(token: token)
    assert_equal user.id, session[Studio.session_key], "first click signs in"

    post link_consume_path(token: token)

    assert_equal user.id, session[Studio.session_key],
                 "the second click must NOT cost the visitor their session"
    refute_equal signin_path, URI.parse(response.location).path,
                 "landing on /signin while holding a valid session is the whole bug"
  end

  test "the second click says nothing — it is just a redirect" do
    user  = users(:alex)
    token = magic_token(email: user.email, age_attested: true)
    post link_consume_path(token: token)
    follow_redirect! # land on the page, which sweeps the sign-in toast

    post link_consume_path(token: token)

    assert_nil flash[:auth_toast], "a spent link of your own is not an event worth announcing"
    assert_nil flash[:alert]
  end

  # A re-click on a link that is still LIVE must not rotate the session either.
  # reset_prior_session! is correct when the identity CHANGES and ruinous when it
  # does not: it drops the onchain flag, geo override, and everything else the
  # visitor had built up, to re-establish the identity they already held.
  test "a re-click on a still-live link does not rotate the session" do
    user = users(:alex)
    post link_consume_path(token: magic_token(email: user.email, age_attested: true))
    before = request.session.id.to_s

    second = magic_token(email: user.email, age_attested: true)
    post link_consume_path(token: second)

    assert_equal user.id, session[Studio.session_key]
    assert_equal before, request.session.id.to_s,
                 "same identity in, same session out — reset_prior_session! must not run here"
    refute_nil Studio::Link.find_by(token: second).consumed_at,
               "the token still burns, so a forwarded email stays unusable"
  end

  # --- a dead link never touches the session ---------------------------------

  test "someone else's expired link leaves your session alone and explains why" do
    log_in_as(users(:alex))
    other = users(:jordan)
    link  = Studio::Link.create_magic_link(email: other.email)
    link.update!(expires_at: 1.hour.ago)

    post link_consume_path(token: link.token)

    assert_equal users(:alex).id, session[Studio.session_key],
                 "an expired link for another person must not log YOU out"
    toast = flash[:auth_toast]&.with_indifferent_access
    refute_nil toast, "turf renders auth_toast only — a notice here would be invisible"
    assert_includes toast[:message], other.email, "the toast names the address the link was for"
    assert_includes toast[:message], users(:alex).email, "and reassures them their session survived"
  end

  test "an unrecognized token leaves a held session alone" do
    log_in_as(users(:alex))

    post link_consume_path(token: "this-token-is-not-real")

    assert_equal users(:alex).id, session[Studio.session_key]
    refute_nil flash[:auth_toast]
  end

  # A referral token is reusable and GET-only. Posted at the consume door it must
  # sign nobody in — and, unlike before, the visitor is told why.
  test "a referral token posted to the consume door signs nobody in" do
    log_in_as(users(:alex))
    referral = Studio::Link.referral_for(users(:jordan))

    post link_consume_path(token: referral.token)

    assert_equal users(:alex).id, session[Studio.session_key]
    assert_nil referral.reload.consumed_at, "a referral link is reusable — it must not burn"
  end

  # --- a live link for someone else still takes over -------------------------

  test "a live link for another user switches the session to them" do
    log_in_as(users(:alex))
    other = users(:jordan)

    post link_consume_path(token: magic_token(email: other.email, age_attested: true))

    assert_equal other.id, session[Studio.session_key],
                 "a LIVE link is proof of ownership, so it outranks the open session"
  end

  # --- signed out, the old behavior is unchanged -----------------------------

  test "a dead link still sends a signed-out visitor to signin" do
    token = magic_token(email: users(:alex).email, age_attested: true)
    post link_consume_path(token: token)
    reset!

    post link_consume_path(token: token)

    assert_redirected_to signin_path
    assert_nil session[Studio.session_key]
  end

  # --- the GET stays inert ----------------------------------------------------

  test "GET on your own spent link redirects instead of rendering the spinner" do
    user  = users(:alex)
    token = magic_token(email: user.email, age_attested: true)
    post link_consume_path(token: token)

    get link_path(token)

    assert_response :redirect, "a dead link is settled on the GET, not spun through a pointless POST"
    assert_equal user.id, session[Studio.session_key]
  end

  test "GET on a live link is still the inert interstitial and does not burn it" do
    token = magic_token(email: users(:alex).email, age_attested: true)

    get link_path(token)

    assert_response :success
    assert_nil session[Studio.session_key], "the GET must not sign anyone in"
    assert_nil Studio::Link.find_by(token: token).consumed_at, "the GET must not burn the token"
  end
end
