require "test_helper"

# [component] + [integration] The hero laptop's simulated touchdowns on
# /turf-monster-v2, over the FICTIONAL showcase (LaptopFictionalShowcase): the
# snapshot opens the featured 49ers at Cowboys game at 3-7, the page carries
# the simulation hook (the featured game, the opening score, every frame drawn
# by the live page's own partials, the scripted Mason/Turf board, the live
# page's own script), and nothing is written to the database.
class LaptopScoreSimRenderTest < ActionDispatch::IntegrationTest
  FOCUS = LaptopFictionalShowcase::FOCUS_SLUG
  CONTEST_ID = LaptopFictionalShowcase::CONTEST_ID

  setup do
    SeasonConfig.set_main_contest!(nil)
  end

  def page_laptop
    get turf_monster_v2_path
    assert_response :success
    css_select('[data-test="laptop-mock"]').first.tap { |node| assert node, "the laptop renders" }
  end

  def featured_scores(node)
    tile = node.css('[data-test="live-focus-game"]').find { |t| t["data-focus-slug"] == FOCUS }
    tile.css('[data-role="team-row"] [data-role="score"]').map { |s| s.text.strip.to_i }
  end

  def board_order(node)
    node.css("[data-entry-slug]").map { |r| r["data-entry-slug"] }.uniq
  end

  test "the featured game opens at 3-7, in progress, with the field goal and touchdown in its rail" do
    live = page_laptop.at_css('[data-test="laptop-live"]')
    assert_equal [3, 7], featured_scores(live), "49ers 3, Cowboys 7"
    rail = live.css('[data-test="live-focus-event"]').map { |e| e["data-event-label"] }
    assert_equal %w[Touchdown Field\ Goal], rail, "newest first"
    chip = live.css('[data-test="live-game-chip"]').find { |c| c["data-game-slug"] == FOCUS }
    assert_equal %w[3 7], chip.css('[data-role="score"]').map { |s| s.text.strip }
    assert_includes chip.text, "Live"
  end

  test "the page carries the simulation hook: the game, the opening score, every frame, and the live page's script" do
    laptop = page_laptop
    sim = laptop.at_css('[data-test="laptop-sim"]')
    assert sim, "the simulation hook renders"
    assert_equal FOCUS, sim["data-game-slug"]
    assert_equal "3-7", sim["data-opening"]
    assert_equal LaptopScoreSimulation::INTERVAL_MS.to_s, sim["data-interval-ms"]
    assert_equal CONTEST_ID.to_s, sim["data-contest-id"]

    # Frame 0 is the snapshot itself; one template set per touchdown.
    tiles = sim.css('template[data-part="tile"]')
    assert_equal (1..LaptopScoreSimulation::TOUCHDOWNS).map(&:to_s), tiles.map { |t| t["data-frame"] }
    assert_equal tiles.size, sim.css('template[data-part="feed"]').size, "every touchdown announces itself"
    assert_equal [10, 7], featured_scores(tiles[0]), "the first touchdown is the 49ers'"
    assert_equal [24, 28], featured_scores(tiles.last), "the last: the first combined 50 or more, where it stops"
    feed = sim.at_css('template[data-frame="1"][data-part="feed"] [data-event="goal"]')
    assert_equal "touchdown", feed["data-scoring-type"]
    assert_equal "7", feed["data-points"]
    assert_equal "san-francisco-49ers", feed["data-team-slug"]
    assert_equal "", feed["data-scorer"].to_s, "no player is credited with a simulated touchdown"

    # THE BOARD: Mason leads the opening, Turf takes the first touchdown, and
    # the lead swaps on every one after.
    live = laptop.at_css('[data-test="laptop-live"]')
    opening = board_order(live.at_css('[data-test="laptop-live-leaderboard"]'))
    assert_equal %w[showcase-mason showcase-turf], opening
    boards = sim.css('template[data-part="board"]').map { |t| board_order(t) }
    assert_equal LaptopScoreSimulation::TOUCHDOWNS, boards.size
    ([opening] + boards).each_cons(2) { |a, b| assert_equal a.reverse, b, "every touchdown swaps the lead" }

    # A frame is swapped into the x-ignore snapshot, so it carries no Alpine.
    sim.css("template *").each do |node|
      bound = node.attributes.keys.grep(/\A(x-|@|:)/)
      assert_empty bound, "frame markup is inert: #{node.name} #{bound.inspect}"
    end

    # The live page's own machinery, wired to the snapshot's own wrappers.
    assert laptop.at_css("#contest_#{CONTEST_ID}_goal_feed"), "the goal feed the live script observes"
    assert live.at_css("#contest_#{CONTEST_ID}_focus")
    assert live.at_css("#contest_#{CONTEST_ID}_games")
    assert live.at_css("#contest_#{CONTEST_ID}_leaderboard"), "the scripted board is wired for re-ranking"
    assert laptop.at_css("#nfl-score-overlay"), "the live page's scoring banner"
    scripts = laptop.css("script").map(&:text).join
    assert_includes scripts, "_goal_feed", "the live page's script"
    assert_includes scripts, "prefers-reduced-motion", "the driver honours reduced motion"
    assert_includes scripts, "IntersectionObserver"
    assert_includes scripts, "visibilitychange"
    assert_empty live.css("script, turbo-cable-stream-source"), "the snapshot itself still runs no code"
  end

  test "the frames carry no real user, even with real entries in the database" do
    slate = Slate.create!(name: "NFL 2026 Weeks 4-6", slug: "nfl-2026-weeks-4-6-sim", sport: "nfl", starts_at: 20.days.ago)
    contest = Contest.create!(name: "Weeks 4-6 Sim", slug: "weeks-4-6-sim", status: "open", entry_fee_cents: 1900,
                              max_entries: 29, contest_type: "standard", slate: slate, starts_at: 2.days.ago)
    sam = users(:sam)
    sam.update_columns(email: "sam.realname@example.com", username: "samrealhandle",
                       first_name: "Samantha", last_name: "Realsurname")
    contest.entries.create!(user: sam, status: :active)
    laptop = page_laptop
    frames = laptop.at_css('[data-test="laptop-sim"]').css("template").map(&:inner_html).join
    assert_operator frames.size, :>, 0, "there are frames to check"
    ["sam.realname@example.com", "samrealhandle", "Samantha", "Realsurname"].each do |leak|
      refute_includes frames, leak, "a frame must not carry #{leak.inspect}"
      refute_includes laptop.to_html, leak
    end
    refute_match(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}/, frames, "no email address of anyone")
  end

  test "nothing is written" do
    assert_no_difference [-> { Goal.count }, -> { Game.count }, -> { Entry.count }, -> { User.count },
                          -> { Contest.count }, -> { Team.count }, -> { SlateMatchup.count }] do
      page_laptop
    end
  end

  test "while the laptop plays the page opts out of Turbo's cache, so Back re-wires it" do
    page_laptop
    # Turbo reads the LAST turbo-cache-control meta (HeadSnapshot#findMetaElementByName),
    # so this page's must follow the engine's no-preview.
    assert_equal "no-cache", css_select('meta[name="turbo-cache-control"]').last["content"]
  end
end
