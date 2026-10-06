require "test_helper"

# [component] + [integration] The hero laptop's simulated touchdowns on
# /turf-monster-v2: the snapshot opens the featured game at 3-7, the page
# carries the simulation hook (the featured game, the opening score, every
# frame drawn by the live page's own partials, the live page's own script),
# the label renders, the snapshot's times read in Mountain, and nothing is
# written to the database.
class LaptopScoreSimRenderTest < ActionDispatch::IntegrationTest
  # Sat Jun 15 2030, 6:15 PM Mountain (MDT) — which is "Sun 12:15 AM" in UTC,
  # the shape of the bug (a Thursday evening game printed as Friday).
  EVENING_KICKOFF = Time.utc(2030, 6, 16, 0, 15)

  setup do
    SeasonConfig.set_main_contest!(nil)
    Message.delete_all
    Selection.delete_all
    Entry.delete_all
    Contest.delete_all
    slate = Slate.create!(name: "NFL 2026 Weeks 4-6", slug: "nfl-2026-weeks-4-6-sim", sport: "nfl", starts_at: 20.days.ago)
    @contest = Contest.create!(name: "Weeks 4-6 Sim", slug: "weeks-4-6-sim", status: "open", entry_fee_cents: 1900,
                               max_entries: 29, contest_type: "standard", slate: slate, starts_at: 2.days.ago)
    @featured = games(:future_game)
    @evening = Game.create!(slug: "e-at-f-sim", home_team_slug: "team-f", away_team_slug: "team-e",
                            kickoff_at: EVENING_KICKOFF, status: "scheduled", venue: "Test Stadium")
    [@featured, @evening].each do |g|
      SlateMatchup.create!(slate: slate, team_slug: g.home_team_slug, opponent_team_slug: g.away_team_slug, game_slug: g.slug)
    end
    @contest.entries.create!(user: users(:sam), status: :active).tap { |e| e.update_column(:score, 140.0) }
  end

  def page_laptop
    get turf_monster_v2_path
    assert_response :success
    css_select('[data-test="laptop-mock"]').first.tap { |node| assert node, "the laptop renders" }
  end

  def featured_scores(node)
    tile = node.css('[data-test="live-focus-game"]').find { |t| t["data-focus-slug"] == @featured.slug }
    tile.css('[data-role="team-row"] [data-role="score"]').map { |s| s.text.strip.to_i }
  end

  test "the featured game opens at 3-7, in progress, with the field goal and touchdown in its rail" do
    assert_equal @featured.slug, NextContest.live_showcase.focus_slug
    live = page_laptop.at_css('[data-test="laptop-live"]')
    assert_equal [3, 7], featured_scores(live), "away 3, home 7"
    rail = live.css('[data-test="live-focus-event"]').map { |e| e["data-event-label"] }
    assert_equal %w[Touchdown Field\ Goal], rail, "newest first"
    chip = live.css('[data-test="live-game-chip"]').find { |c| c["data-game-slug"] == @featured.slug }
    assert_equal %w[3 7], chip.css('[data-role="score"]').map { |s| s.text.strip }
    assert_includes chip.text, "Live"
  end

  test "the page carries the simulation hook: the game, the opening score, every frame, and the live page's script" do
    laptop = page_laptop
    sim = laptop.at_css('[data-test="laptop-sim"]')
    assert sim, "the simulation hook renders"
    assert_equal @featured.slug, sim["data-game-slug"]
    assert_equal "3-7", sim["data-opening"]
    assert_equal LaptopScoreSimulation::INTERVAL_MS.to_s, sim["data-interval-ms"]
    assert_equal @contest.id.to_s, sim["data-contest-id"]

    # Frame 0 is the snapshot itself; one template set per touchdown.
    tiles = sim.css('template[data-part="tile"]')
    assert_equal (1..LaptopScoreSimulation::TOUCHDOWNS).map(&:to_s), tiles.map { |t| t["data-frame"] }
    assert_equal tiles.size, sim.css('template[data-part="feed"]').size, "every touchdown announces itself"
    assert_equal [10, 7], featured_scores(tiles[0]), "the first touchdown is the away side's"
    assert_equal [24, 28], featured_scores(tiles.last), "the last, before the loop"
    rail = tiles[0].css('[data-test="live-focus-event"]').map { |e| [e["data-event-label"], e.text.squish.split.last] }
    assert_equal [["Touchdown", "+7"], ["Touchdown", "+7"], ["Field Goal", "+3"]], rail, "the scoring-play line arrives with the tile"
    feed = sim.at_css('template[data-frame="1"][data-part="feed"] [data-event="goal"]')
    assert_equal "touchdown", feed["data-scoring-type"]
    assert_equal "7", feed["data-points"]
    assert_equal @featured.away_team_slug, feed["data-team-slug"]
    assert_equal "", feed["data-scorer"].to_s, "no player is credited with a simulated touchdown"

    # A frame is swapped into the x-ignore snapshot, so it carries no Alpine.
    sim.css("template *").each do |node|
      bound = node.attributes.keys.grep(/\A(x-|@|:)/)
      assert_empty bound, "frame markup is inert: #{node.name} #{bound.inspect}"
    end

    # The live page's own machinery, wired to the snapshot's own wrappers.
    assert laptop.at_css("#contest_#{@contest.id}_goal_feed"), "the goal feed the live script observes"
    live = laptop.at_css('[data-test="laptop-live"]')
    assert live.at_css("#contest_#{@contest.id}_focus")
    assert live.at_css("#contest_#{@contest.id}_games")
    assert_nil laptop.at_css("#contest_#{@contest.id}_leaderboard"), "the leaderboard is never wired: it keeps its real numbers"
    assert laptop.at_css("#nfl-score-overlay"), "the live page's scoring banner"
    scripts = laptop.css("script").map(&:text).join
    assert_includes scripts, "_goal_feed", "the live page's script"
    assert_includes scripts, "prefers-reduced-motion", "the driver honours reduced motion"
    assert_includes scripts, "IntersectionObserver"
    assert_includes scripts, "visibilitychange"
    assert_empty live.css("script, turbo-cable-stream-source"), "the snapshot itself still runs no code"
  end

  test "the laptop is labelled as simulated" do
    label = page_laptop.at_css('[data-test="laptop-sim-label"]')
    assert label, "the label renders"
    assert_equal LaptopScoreSimulation::LABEL, label.text.strip
  end

  test "the snapshot's kickoff times read in Mountain, not UTC" do
    live = page_laptop.at_css('[data-test="laptop-live"]')
    chip = live.css('[data-test="live-game-chip"]').find { |c| c["data-game-slug"] == @evening.slug }
    time = chip.at_css('time[data-role="kickoff"]')
    assert_equal "Sat 6:15 PM", time.text.strip
    refute_includes live.text, "Sun 12:15 AM"
    assert_equal EVENING_KICKOFF.iso8601, time["datetime"], "the machine-readable instant is unchanged"
  end

  test "nothing is written: the real game, its goals and the leaderboard stay as they were" do
    before = @featured.reload.attributes
    assert_no_difference [-> { Goal.count }, -> { Game.count }] do
      page_laptop
    end
    assert_equal before, @featured.reload.attributes
    board = css_select('[data-test="laptop-live-leaderboard"]').first
    assert_includes board.text, "140", "the real entry score"
  end

  test "with no live or finished contest there is no simulation" do
    Entry.delete_all
    Contest.delete_all
    laptop = page_laptop
    assert_nil laptop.at_css('[data-test="laptop-sim"]')
    assert_nil laptop.at_css('[data-test="laptop-sim-label"]')
  end
end
