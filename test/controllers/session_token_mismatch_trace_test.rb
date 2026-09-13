require "test_helper"

# OPSEC-045's forced logout, and the DURABLE TRACE it leaves — added 2026-09-09.
#
# ⚠️ READ THIS BEFORE ADDING A TEST HERE. The event under test is a redirect,
# and a redirect is the shape in which an inert test breeds: `assert_redirected_to
# signin_path` passes with the recording deleted, because the recording was never
# what produced the redirect. So every test below that means "it recorded"
# asserts on the ROW, and the one that asserts the redirect is explicitly the
# FAIL-OPEN test, where a logout with no row is the correct outcome.
#
# THE HOLE THIS CLOSES. `ApplicationController#verify_session_token` used to emit
# a `Rails.logger.info` line and nothing else. Rails logs are not a triage
# surface in this app — error_logs is, and it is where every other user-facing
# failure lands — so the one event that ends a session against the user's will
# was the one event nobody could find afterwards.
#
# WHY IT BELONGS TO THE WALLET WORK. A `session_token` mismatch answers a
# non-HTML request through `format.html`: a 302 to /signin, which `fetch`
# FOLLOWS to an HTML body at status 200. That is one of the two shapes
# `window.solanaConnectAndVerify`'s verify guard substitutes a server sentence
# for (test/views/verify_server_failure_copy_test.rb). The guard is right to do
# it — the user must be told something true — but the substitution costs the
# CAUSE, so without a row "our server could not finish sign-in" is the most
# anyone could ever learn about it. PR 644 argued from reportability; this is
# the half of that argument the verify leg could not supply for itself.
class SessionTokenMismatchTraceTest < ActionDispatch::IntegrationTest
  setup { @user = users(:alex) }

  # This app's real sign-in — there is no test-only login route, and a session
  # needs BOTH session[:turf_user_id] and session[:session_token]. It ASSERTS it
  # worked: a setup step that quietly does nothing would leave every test below
  # running signed out, where verify_session_token returns early on `true_user`
  # and every "no row" assertion passes for the wrong reason.
  def sign_in_as(user)
    link = Studio::Link.create_magic_link(email: user.email, return_to: "/", ttl: 1.hour)
    get "/l/#{link.token}"
    post "/l/#{link.token}"
    get "/account"
    assert_response :success, "sign-in did not take — every assertion below would run signed out"
  end

  # Rotating the durable token is what a password change does to every OTHER
  # live session. It is the real producer of this event, not a hand-built cookie.
  def rotate_token!(user)
    user.update!(session_token: SecureRandom.hex(16))
  end

  # ── It records ──────────────────────────────────────────────────────────────

  test "a forced logout creates an ErrorLog row" do
    sign_in_as(@user)
    rotate_token!(@user)

    assert_difference "ErrorLog.count", 1 do
      get "/account"
    end

    log = ErrorLog.last
    assert_includes log.inspect_field, "SessionTokenMismatch",
                    "the row must be findable by the class that names this event — " \
                    "'was this user kicked out?' has to be a query, not a guess"
    assert_includes log.message, "user_id=#{@user.id}"
  end

  test "the row targets the user who was logged out" do
    # Stated as a test because this app's on-chain rows target the ENTRY, so an
    # operator searching error_logs by user comes back empty and reads it as
    # "nothing was logged". The subject of THIS failure is a person's session.
    sign_in_as(@user)
    rotate_token!(@user)
    get "/account"

    assert_equal @user, ErrorLog.last.target
  end

  test "neither session token reaches the row" do
    # Both halves of the comparison are credentials. The row records only
    # WHETHER the cookie carried one, which is the whole diagnostic difference:
    # absent means a session predating the binding, stale means a rotation, a
    # revoked sibling session, or a stolen cookie meeting one.
    sign_in_as(@user)
    old_token = @user.session_token
    rotate_token!(@user)
    get "/account"

    log = ErrorLog.last
    refute_includes log.message.to_s, old_token,
                    "the cookie's token is a credential and must never be written down"
    refute_includes log.message.to_s, @user.reload.session_token,
                    "neither is the durable one it was compared against"
    assert_includes log.message, "present but stale"
  end

  # ── It stays out of the way ─────────────────────────────────────────────────

  test "a matching session records nothing" do
    # The floor under every test above. If a row were filed on ordinary
    # requests, the counts above would be describing noise rather than an event,
    # and the operator filter this exists to create would be worthless.
    sign_in_as(@user)

    assert_no_difference "ErrorLog.count" do
      get "/account"
      get "/account"
    end
  end

  test "a recorder fault still logs the user out" do
    # THE FAIL-OPEN CONTRACT, and the reason it is not optional: a forced logout
    # is a SECURITY act. A logger that can veto the thing it observes is worse
    # than no logger, so the recorder swallows its own faults. This is the ONE
    # test here that asserts the redirect rather than the row — here a logout
    # with NO row is the correct outcome.
    sign_in_as(@user)
    rotate_token!(@user)

    # The write itself is what fails — the realistic fault, and the one that
    # exercises the rescue rather than a stand-in for it.
    raiser = ->(_exception) { raise ActiveRecord::StatementInvalid, "error_logs is down" }

    ErrorLog.stub :capture!, raiser do
      assert_no_difference "ErrorLog.count" do
        get "/account"
      end
    end

    assert_redirected_to signin_path,
                         "a failure inside the recorder must never keep a stale session alive"
  end
end
