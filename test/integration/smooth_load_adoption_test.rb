require "test_helper"

# Page-level guard for the smooth-load adoption (task: turf-monster-smooth-load).
#
# With Studio.smooth_load = true, the engine head partial (layouts/studio/head,
# rendered by TM's application + landing layouts) emits the two Turbo 8 metas —
# view-transition same-origin (start a view transition on same-origin visits)
# and turbo-cache-control no-preview (never flash a stale cache preview as the
# transition's "old" frame) — and the navbar header carries vt-pinned-header so
# it stays visually pinned while the page body cross-fades.
#
# The count-1 assertions are load-bearing: a SECOND pinned element gives two
# elements the same view-transition-name, which silently disables ALL view
# transitions on the page (no error, just a dead feature). The admin
# navbar-review page is the live duplicate hazard — it renders preview copies
# of the navbar partial inside the body.
class SmoothLoadAdoptionTest < ActionDispatch::IntegrationTest
  test "[integration] public page emits the smooth-load metas and exactly one pinned header" do
    get signin_path
    assert_response :success

    assert_select 'meta[name="view-transition"][content="same-origin"]', count: 1
    assert_select 'meta[name="turbo-cache-control"][content="no-preview"]', count: 1
    assert_select "header.vt-pinned-header", count: 1
  end

  test "[integration] a page names the direction and loads the transition module" do
    get signin_path
    assert_response :success

    assert_select %q(meta[name="page-transition-direction"][content="right"]), count: 1
    assert_includes response.body, "studio/page_transitions"
  end

  # engine 0.125.0: a signing page stays its own document, so its move is the browser's
  # cross-document view transition, and both documents must carry the sheet and the script.
  test "[integration] a signing page and a Turbo page both carry the full-load sheet and script" do
    [ contest_path(contests(:one)), signin_path ].each do |path|
      get path
      assert_response :success

      assert_select %q(link[rel="stylesheet"][href*="studio/page_transition_full_load"]), count: 1
      assert_select %q(script[src*="studio/page_transition_reveal"]), count: 1
    end
  end

  test "[integration] the full-load script takes the nonce the strict policy names" do
    was = Rails.configuration.x.signing_csp_enforced
    Rails.configuration.x.signing_csp_enforced = true
    begin
      get contest_path(contests(:one))
    ensure
      Rails.configuration.x.signing_csp_enforced = was
    end
    assert_response :success
    assert_select %q(meta[name="signing-csp"]), count: 1

    policy = response.headers["Content-Security-Policy"]
    script = css_select(%q(script[src*="studio/page_transition_reveal"])).first
    assert script, "the signing page renders no full-load script"
    assert script["nonce"].present?, "the full-load script carries no nonce"
    assert_includes policy, "'nonce-#{script['nonce']}'"
  end

  # The session is the cookie, so a slow read that writes it can undo a form that landed first:
  # measured on an Act as. The load-time balance reads must leave the cookie alone.
  test "[integration] the balance reads do not write the session cookie" do
    log_in_as(users(:alex))
    [ "/account/session_refresh", "/admin/usdc_balance" ].each do |path|
      get path, headers: { "Accept" => "application/json" }
      assert_response :success, path
      session_cookie = Array(response.headers["Set-Cookie"]).join("\n")
      assert_no_match(/_session=/, session_cookie, "#{path} wrote the session cookie")
    end
  end

  test "[integration] admin navbar-review page keeps exactly one pinned header despite preview copies" do
    log_in_as(users(:alex))
    get admin_navbar_path
    assert_response :success

    # The page renders the real layout navbar PLUS preview: true copies in the
    # body — more than one header element total, but only the real one pinned.
    assert_select "header[data-navbar-root]", minimum: 2
    assert_select "header.vt-pinned-header", count: 1
  end
end
