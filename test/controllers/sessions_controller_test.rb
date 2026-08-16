require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  test "signin page renders" do
    get signin_path
    assert_response :success
  end

  test "signin page shows the QA non-production banner when QA_ENV is enabled" do
    original = ENV["QA_ENV"]
    ENV["QA_ENV"] = "true"

    get signin_path

    assert_response :success
    assert_match(/QA Environment/, response.body)
    assert_match(/Non-production/, response.body)
    assert_match(/data-app-environment="qa"/, response.body)
  ensure
    original.nil? ? ENV.delete("QA_ENV") : ENV["QA_ENV"] = original
  end

  # An already-logged-in viewer hitting /signin is bounced to their account by
  # redirect_if_authenticated, instead of a dead-end form. (/login + /signup
  # 301 to /signin first, so the guard lives on /signin.)
  test "authenticated user GET /signin is redirected to account" do
    log_in_as users(:alex)
    get signin_path
    assert_redirected_to account_path
  end

  # A relative ?return_to is honoured so a deep-linked authed user lands where
  # they intended (safe_return_to).
  test "authenticated user GET /signin honours a relative return_to" do
    log_in_as users(:alex)
    get signin_path(return_to: "/contests")
    assert_redirected_to "/contests"
  end

  # An absolute/protocol-relative return_to is ignored (open-redirect guard).
  test "authenticated user GET /signin ignores an off-site return_to" do
    log_in_as users(:alex)
    get signin_path(return_to: "//evil.example.com")
    assert_redirected_to account_path
  end

  # Unified auth: legacy /login + /signup 301-redirect to /signin (query preserved).
  test "legacy /login + /signup redirect to /signin" do
    get login_path
    assert_redirected_to signin_path

    get signup_path
    assert_redirected_to signin_path

    get "/signup", params: { reference: "spring" }
    assert_redirected_to "/signin?reference=spring"
  end

  # Passwordless: log_in_as goes through the magic-link consume. A returning
  # login with no return_to lands on the ROOT (operator call, 2026-08-15), which
  # is contests#world_cup — a redirector to the live featured contest, the
  # destination this used to reach in one hop.
  test "login via magic link establishes a session" do
    log_in_as users(:alex)
    assert_redirected_to root_path
    follow_redirect!
    assert_redirected_to contest_path(contests(:one))
    assert_equal users(:alex).id, session[Studio.session_key]
  end

  # POST /login no longer authenticates a password — any POST is bounced to
  # /signin with a magic-link hint. This is the core of Lazarus audit #4: there
  # is no password path to attack.
  test "create does NOT log in via password — bounces to magic link" do
    post login_path, params: { email: "alex@mcritchie.studio", password: "password" }
    assert_redirected_to signin_path
    assert_nil session[Studio.session_key], "a password POST must NOT establish a session"
    follow_redirect!
    assert_match(/magic link/i, flash[:alert].to_s)
  end

  test "create with no params still just bounces" do
    post login_path
    assert_redirected_to signin_path
    assert_nil session[Studio.session_key]
  end

  test "logout clears session" do
    log_in_as users(:alex)
    get logout_path
    assert_redirected_to signin_path
    assert_nil session[Studio.session_key]
  end
end
