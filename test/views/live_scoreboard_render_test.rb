require "test_helper"

# [component] The /live scoreboard, as it actually renders.
class LiveScoreboardRenderTest < ActionDispatch::IntegrationTest
  setup do
    @home = teams(:team_a)
    @away = teams(:team_b)
    @away.update!(league: "nfl", sport: "football")
    # Brand colors are the tile's whole visual language, so pin real values.
    # Name/location are Giants-shaped on purpose: the row must show the MASCOT.
    @home.update!(name: "New York Giants", location: "New York", mascot: nil,
                  color_dark: "#97233F", color_light: "#FFB612", color_disposition: "dark")
    @game = Game.create!(
      home_team_slug: @home.slug, away_team_slug: @away.slug,
      season_year: 2026, season_type: 1, week: 4,
      status: "in_progress", status_detail: "Q3 8:42", period: 3, clock: "8:42",
      kickoff_at: 1.hour.ago
    )
    @game.goals.create!(team_slug: @home.slug, points: 6, scoring_type: "touchdown")
    @game.goals.create!(team_slug: @away.slug, points: 3, scoring_type: "field_goal")
  end

  # Public on purpose: a scoreboard that demands a sign-in to show a score is
  # not a scoreboard.
  test "renders without a signed-in user" do
    get live_path

    assert_response :success
    assert_select "[data-test=?]", "live-game-tile"
  end

  test "shows each team's summed score, not its number of scoring events" do
    get live_path

    assert_response :success
    assert_select "[data-game-slug=?]", @game.slug do
      assert_select "[data-role=score]", text: "6"
      assert_select "[data-role=score]", text: "3"
    end
  end

  # The row is a TEAM CARD, painted through the app's existing team_card_palette
  # rather than a second convention invented for this page — the field is a
  # gradient in the team's own hue.
  test "paints each row as a gradient in that team's brand hue" do
    get live_path

    assert_match(/linear-gradient\([^)]*#97233f/i, response.body)
  end

  # Colour continuity with contests/_multi_week_team_card: the MASCOT wears the
  # team accent over its legibility halo, the CITY wears the light location
  # colour. Same helper, same two values, so the two pages cannot drift.
  test "paints the mascot in the team accent and the city in the location color" do
    get live_path

    assert_select "[data-game-slug=?] [data-team-slug=?]", @game.slug, @home.slug do |rows|
      html = rows.first.to_s
      assert_match(/color:\s*#ffb612[^"]*text-shadow/i, html,
        "the mascot should carry the accent colour AND its halo")
    end
  end

  # The ring lives on the CARD and starts dark. Opacity 0 rather than an absent
  # class, so the engine's own 0.4s opacity transition can fade it in and out.
  test "each card hosts a team glow ring, dark until a score lights it" do
    get live_path

    assert_select "[data-test=?][data-game-slug=?]", "live-game-tile", @game.slug do |cards|
      style = cards.first["style"]
      assert_includes cards.first["class"], "studio-team-glow"
      assert_match(/--studio-team-glow-opacity:\s*0/, style)
      refute_includes cards.first["class"], "overflow-hidden",
        "overflow-hidden on the host would clip the ring away entirely"
    end
  end

  # The name line is the MASCOT, not the ESPN abbreviation: "Giants" over
  # "New York", never "NYG". The abbreviation is a feed detail and the location
  # line already carries the city.
  test "names each team by its mascot, with the city underneath" do
    get live_path

    assert_select "[data-game-slug=?] [data-team-slug=?]", @game.slug, @home.slug do
      assert_select "*", text: "Giants"
      assert_select "*", text: "New York"
      assert_select "*", text: "NYG", count: 0
    end
  end

  # The row carries BOTH brand colors, because they do different jobs: the field
  # backs the wash and the rail glow, the ink colors the score. Shipping only the
  # field is not a cosmetic slip — Pittsburgh's is #101820, so the score that
  # just changed renders near-black on a dark board and reads as not having
  # changed at all.
  test "each row exposes the team's field AND ink colors to the animations" do
    get live_path

    assert_select "[data-game-slug=?] [data-team-slug=?]", @game.slug, @home.slug do |rows|
      style = rows.first["style"]
      assert_match(/--nfl-team:\s*#97233F/i, style)
      assert_match(/--nfl-team-ink:\s*#FFB612/i, style)
    end
  end

  test "each row carries the wash, rail and sweep the animations target" do
    get live_path

    assert_select "[data-game-slug=?]", @game.slug do
      assert_select ".nfl-row-wash", count: 2
      assert_select ".nfl-rail", count: 2
      assert_select ".nfl-sweep", count: 2
    end
  end

  # The sweep travels by translateX in PERCENT, so its width is not decoration —
  # a width that fails to apply makes the strip travel zero pixels while still
  # fading in and out, which looks like a stationary glow and raises no error.
  # A stale build once removed it; inline keeps a dimension the animation's
  # arithmetic depends on from going missing because of build ordering.
  test "the touchdown sweep carries an explicit width, not a build-order casualty" do
    get live_path

    assert_select ".nfl-sweep" do |sweeps|
      assert_match(/width:\s*\d+%/, sweeps.first["style"])
    end
  end

  test "labels a live game with its clock and a final game as final" do
    get live_path
    assert_select "[data-game-slug=?]", @game.slug do
      assert_select "*", text: /Q3 8:42/
      assert_select "*", text: /Live/i
    end

    @game.update!(status: "completed", status_detail: "Final")
    get live_path
    assert_select "[data-game-slug=?]", @game.slug do
      assert_select "*", text: /Final/
    end
  end

  test "titles the board with its season slot" do
    get live_path

    assert_select "h1", text: /Preseason/
    assert_select "h1", text: /Week 4/
  end

  # The stream subscription is what makes this page live at all — without it
  # the board is a snapshot that silently goes stale.
  test "subscribes to the nfl_live stream" do
    get live_path

    assert_select "turbo-cable-stream-source"
    assert_select "#nfl_live_scoreboard"
    assert_select "#nfl_live_event_feed"
  end

  # The dev toolbar writes real Goal rows. It must never be drawn in production.
  test "renders the dev score toolbar outside production" do
    get live_path

    assert_select "[data-test=?]", "dev-score-tools"
    assert_select "[data-test=?]", "dev-score-touchdown"
    assert_select "[data-test=?]", "dev-score-clear"
    assert_select "[data-test=?]", "dev-score-conclude"
  end

  # One across on a phone, two on a tablet, four on a desktop. Asserted on the
  # classes because the breakpoints ARE the requirement — a grid that silently
  # drops back to three columns still renders perfectly and is still wrong.
  test "lays the board out one-up, two-up on tablet, four-up on desktop" do
    get live_path

    assert_select "#nfl_live_scoreboard .grid" do |grids|
      classes = grids.first["class"]
      assert_includes classes, "md:grid-cols-2"
      assert_includes classes, "xl:grid-cols-4"
    end
  end

  # A concluded game showed "Final" twice — once as the badge, once as ESPN's
  # shortDetail. The detail is kept only when it adds something.
  test "does not print Final twice on a concluded game" do
    @game.update!(status: "completed", status_detail: "Final")
    get live_path

    assert_select "[data-game-slug=?]", @game.slug do |cards|
      assert_equal 1, cards.first.to_s.scan(/Final/).length
    end
  end

  test "keeps a status detail that says more than the badge" do
    @game.update!(status: "completed", status_detail: "Final/OT")
    get live_path

    assert_select "[data-game-slug=?]", @game.slug do
      assert_select "*", text: "Final/OT"
    end
  end

  test "the dev toolbar is gated on the environment, not on markup alone" do
    Rails.env.stub(:local?, false) do
      get live_path

      assert_response :success
      assert_select "[data-test=?]", "dev-score-tools", count: 0
    end
  end
end
