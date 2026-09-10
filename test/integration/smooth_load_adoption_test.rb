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
