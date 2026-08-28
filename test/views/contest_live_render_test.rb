require "test_helper"

# [component] The contest live page, as it actually renders.
#
# The page's whole job is to say what CHANGED, and almost everything it says is
# said in markup this test can see: the tile it draws each game with, the marks
# that identify the reader's own team and own entry, the hooks the ranking
# script keys off. What it cannot see is the motion — that is the operator's
# call at the QA stop — so every assertion here is about the STATE the motion
# reads from, which is the half that can silently rot.
class ContestLiveRenderTest < ActionDispatch::IntegrationTest
  setup do
    @contest = contests(:one)
    # live? is locked? && !settled?, and locked? is derived from starts_at.
    @contest.update!(starts_at: 1.hour.ago, status: "open")

    # Brand colours pinned, because the tile's entire visual argument is that a
    # game is drawn in its two teams' own hues.
    #
    # COLOURS ONLY — deliberately not the name. Team includes Sluggable, which
    # re-stamps the slug on every save, and slate_matchups join to teams BY SLUG.
    # Renaming team-a here silently orphaned every matchup pointing at it, and
    # the page died on `card_background for nil` two partials away from the edit.
    teams(:team_a).update!(color_dark: "#241773", color_light: "#9E7C0C", color_disposition: "dark")
    teams(:team_b).update!(league: "nfl", sport: "football")

    @played = games(:past_game)        # team-a vs team-b, completed
    @upcoming = games(:future_game)    # team-c vs team-d, scheduled
    slate_matchups(:m1).update!(game_slug: @played.slug)
    slate_matchups(:m2).update!(game_slug: @played.slug)
    slate_matchups(:m3).update!(game_slug: @upcoming.slug)

    # FIXTURES SKIP CALLBACKS, so the slug Sluggable stamps in before_save on
    # create was never written — and the slug is precisely what the ranking
    # script uses to recognise a row across a full replacement. Re-saving does
    # not fix it (an unchanged record writes nothing), so stamp it the way the
    # create path would. Distinct scores too: two equal scores trip the board's
    # `everyone_equal` branch, which reorders to float the viewer and would make
    # every rank assertion below depend on who is signed in.
    @mine = entries(:one)              # alex
    @theirs = entries(:two)            # jordan
    @mine.update!(score: 12.5)
    @theirs.update!(score: 4.0)
    [@mine, @theirs].each { |entry| entry.update_column(:slug, entry.name_slug) }

    @mine.selections.create!(slate_matchup: slate_matchups(:m1))   # team-a
    @theirs.selections.create!(slate_matchup: slate_matchups(:m3)) # team-c
  end

  def get_live(as: nil)
    log_in_as(as) if as
    get live_contest_path(@contest)
  end

  # The port itself: this page draws the SAME tile the league scoreboard draws.
  # Assert on the league board's own marker, so a future divergence — someone
  # reintroducing a contest-only card — fails here rather than being noticed
  # months later in a screenshot.
  test "draws each game with the league scoreboard's tile" do
    get_live

    assert_response :success
    assert_select "[data-test=?]", "live-game-tile", minimum: 2
  end

  test "paints a game in its two teams' brand hues" do
    get_live

    assert_match(/linear-gradient\([^)]*#241773/i, response.body,
      "the tile should wear the team's own field colour, not a neutral card")
  end

  # The contest-only half of the tile.
  test "marks the rows of teams the viewer picked, and only those" do
    get_live(as: users(:alex))

    assert_select "[data-game-slug=?] [data-team-slug=?][data-picked=?]", @played.slug, "team-a", "1"
    assert_select "[data-game-slug=?] [data-team-slug=?][data-picked=?]", @played.slug, "team-b", "0"
  end

  test "marks nothing for a signed-out reader" do
    get_live

    assert_response :success
    assert_select "[data-picked=?]", "1", count: 0
  end

  # THE STICKY STATE. Contest::LiveBroadcast sends one payload to every
  # subscriber, so anything viewer-specific inside a broadcast target is gone
  # after the first score. These two lists live outside every target precisely
  # so the page can put the marks back — if they stop being rendered, the marks
  # survive the first paint and vanish for the rest of the contest.
  test "publishes the viewer's own entries and picks outside every broadcast target" do
    get_live(as: users(:alex))

    shell = css_select("#contest_#{@contest.id}_viewer").first
    assert_equal @mine.reload.slug, shell["data-entry-slugs"]
    assert_equal "team-a", shell["data-picked-slugs"]
  end

  test "publishes empty sticky state for a signed-out reader" do
    get_live

    shell = css_select("#contest_#{@contest.id}_viewer").first
    assert_equal "", shell["data-entry-slugs"]
    assert_equal "", shell["data-picked-slugs"]
  end

  # The ranking hooks. rank and score are what "who moved" is derived FROM;
  # entry-slug is what makes the derivation possible across a full replacement.
  test "each leaderboard row carries its identity, rank and score" do
    get_live

    assert_select "[data-role=entry-row]", count: 2
    row = css_select("[data-role=entry-row][data-entry-slug='#{@mine.reload.slug}']").first
    assert row, "the viewer's entry should be identifiable by its slug"
    assert_equal "1", row["data-rank"]
    assert_equal "12.5", row["data-score"]
    assert_select "[data-role=entry-row] [data-role=entry-score]", count: 2
  end

  # A first render has nothing to compare against, and a board that claims
  # movement it never observed is worse than one that claims none.
  test "renders the movement slot empty on a first paint" do
    get_live

    assert_select "[data-role=rank-move]", count: 2
    assert_select "[data-role=rank-move]" do |slots|
      slots.each { |slot| assert_equal "", slot.text.strip }
    end
  end

  # THE LAYOUT: a strip of every game across the top, one of them shown at full
  # size in the left column, the ranking down the right.
  test "renders one chip per game in the strip" do
    get_live

    assert_select "[data-test=?]", "live-game-chip", count: 2
  end

  # Every game is rendered into the focus panel and all but one is hidden, so
  # switching is instant and a broadcast refreshes the fifteen you might switch
  # to as well as the one you are watching. The inline display:none is what
  # keeps the page from opening as a column of sixteen games — Alpine boots
  # after first paint, so x-show alone is too late.
  test "renders every game into the focus panel with exactly one visible" do
    get_live

    assert_select "[data-test=?]", "live-focus-game", count: 2
    shown = css_select("[data-test='live-focus-game']").reject { |el| el["style"].to_s.include?("display: none") }
    assert_equal 1, shown.size, "exactly one focus tile should be visible on first paint"
  end

  # It opens on what is being played; with nothing live, on what is next. The
  # strip is laid out in the same order, so the opening game is the chip at the
  # far left rather than one buried mid-row.
  test "opens focused on the next game when nothing is live" do
    get_live

    shown = css_select("[data-test='live-focus-game']").reject { |el| el["style"].to_s.include?("display: none") }
    assert_equal @upcoming.slug, shown.first["data-focus-slug"]
    assert_select "[x-data=?]", "{ focus: '#{@upcoming.slug}' }"
  end

  # The chip and the full tile draw the same game, and a score has to light both.
  # The page's script queries all matching rows rather than the first, which only
  # works while both carry the hooks.
  test "chip and focus tile share the animation hooks" do
    get_live

    %w[live-game-chip live-focus-game].each do |marker|
      assert_select "[data-test='#{marker}'] [data-team-slug='team-a'] [data-role=score]",
                    { minimum: 1 }, "#{marker} should expose a score the scoring animation can find"
    end
  end

  # The cut line sits after the last PAYING rank, not after the last entry —
  # contest :one is a standard format, which pays five.
  test "draws the money line after the last paying rank" do
    get_live

    assert_equal 5, @contest.payouts.keys.map(&:to_i).max
    assert_select "[data-test=?]", "leaderboard-money-line", count: 1
  end
end
