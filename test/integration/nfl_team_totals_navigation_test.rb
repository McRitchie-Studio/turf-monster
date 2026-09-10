require "test_helper"

class NflTeamTotalsNavigationTest < ActionDispatch::IntegrationTest
  # REBOUND, not deleted. This asserted `header a[href=...]` — the link's old
  # ADDRESS in the navbar — and the operator moved NFL Totals into the gear
  # sidebar to give the wordmark room. The concern the test was defending is not
  # "it lives in the header"; it is "a visitor can get to this page from the site
  # chrome". Pin that instead, at both audiences, because the sidebar and the
  # footer serve different ones.
  test "a logged-out visitor can reach the NFL totals page from the footer" do
    get games_path

    assert_response :success
    # The gear sidebar is `return unless current_user`, so it is not a
    # destination for anonymous traffic — the footer is the only route, and
    # without it this public page is unreachable from every page on the site.
    assert_select "footer a[href=?]", nfl_team_totals_path, text: "NFL Totals"
  end

  test "a signed-in visitor reaches it from the gear sidebar" do
    log_in_as users(:jordan)
    get games_path

    assert_response :success
    # SCOPED ON PURPOSE. An unscoped `a[href=?]` is satisfied by the FOOTER link
    # this same page renders, so this test reported green with the sidebar row
    # deleted — measured. Name the sidebar, or the assertion is decoration.
    assert_select "#gear-sidebar a[href=?]", nfl_team_totals_path, text: /NFL Totals/
  end

  test "the navbar itself no longer carries it" do
    get games_path

    assert_response :success
    # The point of the move: the top bar is down to Contests and Rules so the
    # Turf Monster wordmark has room. A silent re-add would undo that.
    assert_select "header nav a[href=?]", nfl_team_totals_path, count: 0
  end
end
