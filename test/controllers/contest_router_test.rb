require "test_helper"

# /contests/:id IS A ROUTER. Once a single game on the slate has started it
# sends the visitor to the live board; before that it renders the contest page.
# The contest page keeps an address of its own, /contests/:id/contest, which
# never redirects — it is where the live board's "← Contest" button lands, and
# without it that button would bounce straight back to the live board.
class ContestRouterTest < ActionDispatch::IntegrationTest
  setup do
    @contest = contests(:one)
    @game = games(:future_game)
    @game.save! # Sluggable rewrites the slug on save; settle it before pointing a matchup at it
    slate_matchups(:m3).update!(game_slug: @game.slug)
  end

  def start_a_game!
    @game.update!(kickoff_at: 1.minute.ago)
  end

  test "before any game starts the contest URL renders the contest page" do
    get contest_path(@contest)

    assert_response :success
  end

  test "once one game has started the contest URL redirects to the live board" do
    start_a_game!

    get contest_path(@contest)

    assert_redirected_to live_contest_path(@contest)
  end

  test "the contest page URL renders the contest page before any game starts" do
    get contest_page_path(@contest)

    assert_response :success
    assert_select "[data-test='live-state']", count: 0
  end

  test "the contest page URL still renders the contest page after a game starts" do
    start_a_game!

    get contest_page_path(@contest)

    assert_response :success
    assert_select "[data-test='live-state']", { count: 0 }, "this is the contest page, not the live board"
  end

  test "the live board's Contest button points at the contest page, not the router" do
    start_a_game!

    get live_contest_path(@contest)

    assert_response :success
    back = css_select("a").select { |a| a.text.include?("← Contest") }
    assert_equal 1, back.size, "the live board carries exactly one ← Contest button"
    assert_equal contest_page_path(@contest), back.first["href"],
                 "a link to the router would bounce straight back here"
  end

  # The contests lobby (/contests) routes nowhere, whatever has started.
  test "the lobby renders even once a game has started" do
    start_a_game!

    get contests_path

    assert_response :success
    assert_equal "index", @controller.action_name
  end

  # A visitor returning from a full-page sign-in can land on the live board with
  # a cart saved in localStorage, and only the contest page can replay it. The
  # browser half (the hand-off actually firing) is e2e/game_started_lock.spec.js;
  # this pins that the live board carries the hand-off, aimed at the page that
  # never routes. The lobby's half is test/integration/retired_world_cup_survivor_test.rb.
  test "the live board hands a saved cart for this contest back to the contest page" do
    start_a_game!

    get live_contest_path(@contest)

    script = css_select("script").map(&:text).find { |js| js.include?("pendingContestEntry") }
    assert script, "the live board must look for a saved cart"
    assert_includes script, "parsed.contestSlug === #{@contest.slug.to_json}"
    assert_includes script, "window.location.replace(#{contest_page_path(@contest).to_json})"
    assert_not_includes script, "removeItem", "the cart is left for the board to consume"
  end

  test "a contest URL carrying a query is not routed away" do
    start_a_game!

    get contest_path(@contest, add_entry: true)

    assert_response :success
  end

  test "a notice riding the redirect into the contest URL survives the hop to live" do
    start_a_game!
    log_in_as(users(:alex))
    post lock_contest_path(@contest) # an action that redirects to the contest URL with a notice
    assert_redirected_to contest_path(@contest)
    message = flash[:notice]
    assert message.present?, "the lock must set a notice for this test to mean anything"

    follow_redirect!
    assert_redirected_to live_contest_path(@contest)
    follow_redirect!

    assert_equal message, flash[:notice], "the notice must still be there to render on the live board"
  end

  test "a retired-format contest is never routed to a live board it does not have" do
    start_a_game!
    write_retired_format!(@contest, keep_slate: true)
    assert @contest.retired_format?

    get contest_path(@contest)

    assert_not response.redirect?, "a retired format has no live board; #live sends it back here, so this would loop"
  end

  test "a pending contest is as invisible at the contest page URL as at the contest URL" do
    @contest.update_columns(status: "pending")

    get contest_page_path(@contest)

    assert_redirected_to contests_path
  end
end
