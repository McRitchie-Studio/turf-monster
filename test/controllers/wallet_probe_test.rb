require "test_helper"

# /wallet_probe — the empty page the wallet-setup modal frames to notice a
# just-installed Phantom without reloading the page the user is reading.
#
# THE WHOLE MECHANISM RESTS ON A HEADER. Chrome puts an extension only into
# documents created after the install, so detection needs a fresh document; the
# app forbids being framed at all (frame-ancestors 'none', clickjacking); and a
# frame the browser refuses to load reports nothing the modal can act on — the
# row would simply sit on "Waiting…" forever, with no error anywhere. So the
# exception is asserted here, and so is its narrowness.
class WalletProbeTest < ActionDispatch::IntegrationTest
  # CSP is enforced in production and report-only everywhere else, so the policy
  # travels under one of two header names depending on the env this runs in.
  def csp_header
    response.headers["Content-Security-Policy"] ||
      response.headers["Content-Security-Policy-Report-Only"]
  end

  test "the probe page is served, and served as a document" do
    get wallet_probe_path
    assert_response :success
    assert_equal "text/html", response.media_type,
                 "a content script runs on an HTML document; anything else is not one"
    assert_includes response.body, "<!DOCTYPE html>"
  end

  test "the probe page may be framed by us" do
    get wallet_probe_path
    assert_response :success

    policy = csp_header
    assert policy.present?, "no CSP header at all — the app's policy stopped applying here"
    assert_includes policy, "frame-ancestors 'self'",
                    "the modal frames this page; 'none' makes detection impossible"
    assert_not_includes policy, "frame-ancestors 'none'"
    assert_equal "SAMEORIGIN", response.headers["X-Frame-Options"],
                 "X-Frame-Options is the second lock on the same door"
  end

  test "the exception does not leak to any other page" do
    # The narrowness IS the security property. If this ever goes red, the whole
    # app became frameable and the clickjacking guard is gone.
    get contests_path
    assert_response :success
    assert_includes csp_header, "frame-ancestors 'none'",
                    "only the probe page may be framed; everything else stays sealed"
  end

  test "the probe page is never cached" do
    get wallet_probe_path
    assert_includes response.headers["Cache-Control"].to_s, "no-store",
                    "a cached document was created BEFORE the install, so it " \
                    "carries no provider and answers every probe with a stale no"
  end

  test "a signed-out visitor gets the probe page, not a redirect" do
    # The frame must land on THIS document. A redirect (login, geo hold, profile
    # completion) lands it on a page whose CSP forbids framing, and the modal
    # then reads a cross-origin-ish frame it cannot inspect — silent blindness.
    get wallet_probe_path
    assert_response :success
  end

  test "a geo-blocked or profile-incomplete user still gets the probe page" do
    # The filters that would otherwise redirect live on ApplicationController;
    # this controller deliberately does not inherit from it. Drive a user the
    # app has real reasons to bounce and prove the probe still answers.
    user = users(:jordan)
    user.update_columns(first_name: nil, date_of_birth: nil)
    log_in_as user

    get wallet_probe_path
    assert_response :success
    assert_includes response.body, "<!DOCTYPE html>"
  end

  test "the probe page carries nothing worth framing" do
    # The justification for relaxing frame-ancestors: there is no data, no
    # control, and no script here to clickjack. Assert that stays true.
    get wallet_probe_path
    assert_response :success
    assert_not_includes response.body, "<script"
    assert_not_includes response.body, "<form"
    assert_not_includes response.body, "<a "
    assert_includes response.body, "noindex"
  end

  test "the modal points its frame at the route this controller draws" do
    # The seam between the two halves: the modal hard-codes the path in its
    # Alpine attribute (it cannot call a route helper from there), so a rename
    # here would leave the frame loading a 404 that detects nothing.
    modal = Rails.root.join("app/views/modals/_wallet_setup.html.erb").read
    assert_includes modal, "'/wallet_probe?t='",
                    "the modal must frame the probe route, cache-busted per attempt"
    assert_equal "/wallet_probe", wallet_probe_path
  end
end
