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

  test "root goes straight to the live board once a game has started" do
    start_a_game!
    featured = @contest
    Contest.stub(:featured, featured) do
      get root_path
    end

    assert_redirected_to live_contest_path(@contest)
  end

  test "root goes to the contest URL before any game starts" do
    featured = @contest
    Contest.stub(:featured, featured) do
      get root_path
    end

    assert_redirected_to contest_path(@contest)
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

  test "a survivor contest is never routed to a live board it does not have" do
    start_a_game!
    @contest.update_columns(game_type: "world_cup_survivor")
    assert @contest.reload.world_cup_survivor?

    get contest_path(@contest)

    assert_not response.redirect?, "survivor has no live board; #live sends it back here, so this would loop"
  end

  test "a pending contest is as invisible at the contest page URL as at the contest URL" do
    @contest.update_columns(status: "pending")

    get contest_page_path(@contest)

    assert_redirected_to root_path
  end
end
