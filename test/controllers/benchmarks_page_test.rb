require "test_helper"

# [component] /benchmarks — the public pricing board. Public is the point: a
# player asking why a team costs 1.5x must not hit a sign-in wall, so these
# render SIGNED OUT.
class BenchmarksPageTest < ActionDispatch::IntegrationTest
  OPPONENTS = { 4 => "team-c", 5 => "team-d", 6 => "team-e" }.freeze

  setup do
    @span = Slate.create!(name: "NFL 2026 Weeks 4-6", slug: "nfl-2026-weeks-4-6", week: 4)
    # team-a plays all three weeks; team-b has its bye in week 6 and is the
    # stronger side per game, so it must rank ABOVE team-a and price on the
    # bye line — the whole thing this page exists to explain.
    add_games!("team-a", { 4 => 20.0, 5 => 20.0, 6 => 20.0 })
    add_games!("team-b", { 4 => 26.0, 5 => 26.0 })
    Nfl::RepriceSpanSlate.call(slate: @span, apply: true)
  end

  def team!(slug)
    Team.find_or_create_by!(slug: slug) { |team| team.name = slug.titleize }
  end

  def add_games!(team_slug, scores)
    scores.each do |week, score|
      opponent = OPPONENTS.fetch(week)
      game = Game.create!(slug: "#{team_slug}-vs-#{opponent}", home_team_slug: team_slug,
                          away_team_slug: opponent, status: "scheduled", kickoff_at: 10.days.from_now + week.days)
      SlateMatchup.create!(slate: @span, team_slug: team_slug, opponent_team_slug: opponent,
                           game_slug: game.slug, expected_score: score, week: week, status: "pending")
    end
  end

  test "it renders signed out" do
    get benchmarks_path(slug: @span.slug)

    assert_response :success
    assert_select "[data-testid=benchmarks]"
  end

  test "each team shows its games, points per game and frozen multiplier" do
    get benchmarks_path(slug: @span.slug)

    assert_response :success
    rows = css_select("tbody tr").map { |row| css_select(row, "td").map { |cell| cell.text.squish } }
    # rank, team, games, per game, total, multiplier
    assert_equal ["1", "🏳️ Team B bye line", "2", "26.0", "52.0", "1.5x"], rows.first
    assert_equal ["2", "🏳️ Team A", "3", "20.0", "60.0", "2.0x"], rows.second
  end

  test "the stored price is what renders, not a recomputed one" do
    # Settlement multiplies by the stored column; a page that recomputed would
    # drift from it. Move the stored value and the page must follow.
    @span.slate_matchups.where(team_slug: "team-b").update_all(turf_score: 2.7)

    get benchmarks_path(slug: @span.slug)

    assert_select "tbody tr:first-child td:last-child", text: /2\.7x/
  end

  test "a bye span explains the two lines" do
    get benchmarks_path(slug: @span.slug)

    assert_select "[data-testid=benchmarks-two-line]", text: /plays 2 games, not 3/
    assert_select "[data-testid=benchmarks-bye-badge]", 1
  end

  test "a span with no bye says nothing about two lines" do
    full = Slate.create!(name: "NFL 2026 Weeks 7-9", slug: "nfl-2026-weeks-7-9", week: 7)
    # Teams of its own: a Game's slug is regenerated from its home-vs-away pair
    # (Sluggable), so a pair already used in setup cannot appear again here.
    %w[full-a full-b].each { |slug| team!(slug) }
    { 7 => "opp-seven", 8 => "opp-eight", 9 => "opp-nine" }.each_value { |slug| team!(slug) }
    %w[full-a full-b].each do |team_slug|
      { 7 => "opp-seven", 8 => "opp-eight", 9 => "opp-nine" }.each do |week, opponent|
        game = Game.create!(slug: "#{team_slug}-vs-#{opponent}", home_team_slug: team_slug,
                            away_team_slug: opponent, status: "scheduled")
        SlateMatchup.create!(slate: full, team_slug: team_slug, opponent_team_slug: opponent,
                             game_slug: game.slug, expected_score: 21.0, week: week, status: "pending")
      end
    end

    get benchmarks_path(slug: full.slug)

    assert_response :success
    assert_select "[data-testid=benchmarks-two-line]", 0
    assert_select "[data-testid=benchmarks-bye-badge]", 0
  end

  test "it names when the lines were pulled, and says so when they were not" do
    get benchmarks_path(slug: @span.slug)
    assert_select "[data-testid=benchmarks-source]", text: /have not been recorded/

    snapshot = MarketSnapshot.create!(sport: "nfl", year: 2026, week: 5, source: "draftkings_espn_scoreboard",
                                      dataset_path: "db/seeds/data/nfl/2026.csv", checksum: "abc123",
                                      captured_at: Time.zone.parse("2026-09-22 14:30 UTC"),
                                      row_count: 30, posted_count: 0, derived_count: 30)
    NflTeamTotalProjection.create!(year: 2026, week: 5, market_snapshot: snapshot, slate: @span,
                                   game_slug: "team-a-vs-team-d", team_slug: "team-a",
                                   opponent_team_slug: "team-d", home: true, expected_points: 20.0,
                                   basis: "derived", favorite_team_slug: "team-a", favorite_spread: -2.5,
                                   home_spread: -2.5, game_total: 44.5, cached_at: Time.current,
                                   source: "draftkings_espn_scoreboard")

    get benchmarks_path(slug: @span.slug)
    assert_select "[data-testid=benchmarks-source]", text: /Sep 22, 2026/
    assert_select "[data-testid=benchmarks-source]", text: /Every team total derived/
  end

  # Bare /benchmarks has to land somewhere sensible for a player who typed it.
  test "with no slug it opens the next span to kick off" do
    later = Slate.create!(name: "NFL 2026 Weeks 10-12", slug: "nfl-2026-weeks-10-12", week: 10)
    game = Game.create!(slug: "team-a-vs-team-f-later", home_team_slug: "team-a", away_team_slug: "team-f",
                        status: "scheduled", kickoff_at: 60.days.from_now)
    SlateMatchup.create!(slate: later, team_slug: "team-a", opponent_team_slug: "team-f",
                         game_slug: game.slug, expected_score: 20.0, week: 10, status: "pending")

    get benchmarks_path

    assert_response :success
    assert_select "[data-testid=benchmarks]", html: /NFL 2026 Weeks 4-6/
  end

  # --- the chart -----------------------------------------------------------

  test "a bye span draws both lines, each labelled" do
    get benchmarks_path(slug: @span.slug)

    assert_response :success
    assert_select "[data-testid=benchmarks-chart]"
    # TWO renders of the same chart (narrow + wide), so two polylines per line.
    assert_select "[data-testid=benchmarks-chart] polyline", 4
    legend = css_select("[data-testid=benchmarks-chart-legend]").first.text.squish
    assert_equal "3 games 2 games · bye", legend
  end

  test "a span with no bye draws one line and says so" do
    full = Slate.create!(name: "NFL 2026 Weeks 7-9", slug: "nfl-2026-weeks-7-9", week: 7)
    %w[full-a full-b].each { |slug| team! slug }
    { 7 => "opp-seven", 8 => "opp-eight", 9 => "opp-nine" }.each_value { |slug| team! slug }
    %w[full-a full-b].each do |team_slug|
      { 7 => "opp-seven", 8 => "opp-eight", 9 => "opp-nine" }.each do |week, opponent|
        game = Game.create!(slug: "#{team_slug}-vs-#{opponent}", home_team_slug: team_slug,
                            away_team_slug: opponent, status: "scheduled")
        SlateMatchup.create!(slate: full, team_slug: team_slug, opponent_team_slug: opponent,
                             game_slug: game.slug, expected_score: 21.0, week: week, status: "pending")
      end
    end

    get benchmarks_path(slug: full.slug)

    assert_response :success
    assert_select "[data-testid=benchmarks-chart] polyline", 2
    assert_equal "3 games", css_select("[data-testid=benchmarks-chart-legend]").first.text.squish
  end

  # The dots are the STORED prices, not the curve — which is what lets a
  # hand-edited multiplier show up as a dot off its line.
  test "a team dot follows the stored price, not the rule" do
    @span.slate_matchups.where(team_slug: "team-b").update_all(turf_score: 2.7)

    get benchmarks_path(slug: @span.slug)

    assert_select "[data-testid=benchmarks-chart] circle title", text: /Team B — rank 1, 2\.7x/
  end

  test "the chart names both lines to a screen reader" do
    get benchmarks_path(slug: @span.slug)

    label = css_select("[data-testid=benchmarks-chart] svg[role=img]").first["aria-label"]
    assert_match(/3 games runs 1\.0x to 2\.0x/, label)
    assert_match(/2 games · bye runs 1\.5x to 3\.0x/, label)
  end

  # --- the query budget ----------------------------------------------------

  # The page used to ask each span slate for its own first kickoff, so its query
  # count grew with the season. The ceiling matters less than the SHAPE: going
  # from 3 extra slates to 9 must cost NOTHING, which a per-slate query cannot
  # do. (Measured against 0 extra slates the count moves by exactly 1 — the
  # LAYOUT's open-contest lookup, not this controller's — so the flat comparison
  # starts once that has already happened.)
  test "query count is flat in the number of span slates" do
    get benchmarks_path(slug: @span.slug) # warm up: the first request also loads schema
    add_span_slates!(3)
    with_three = count_queries { get benchmarks_path(slug: @span.slug) }
    add_span_slates!(6, offset: 3)
    with_nine = count_queries { get benchmarks_path(slug: @span.slug) }

    assert_equal with_three, with_nine, "six more slates must cost no more queries"
    assert_operator with_nine, :<=, 15, "an uncached public page should not open a dozen round trips"
  end

  def add_span_slates!(count, offset: 0)
    count.times do |index|
      number = 10 + offset + index
      slate = Slate.create!(name: "NFL 2026 Weeks #{number}-#{number + 2}",
                            slug: "nfl-2026-weeks-#{number}-#{number + 2}", week: number)
      opponent = team!("filler-#{number}")
      game = Game.create!(slug: "team-a-vs-#{opponent.slug}", home_team_slug: "team-a",
                          away_team_slug: opponent.slug, status: "scheduled", kickoff_at: 30.days.from_now)
      SlateMatchup.create!(slate: slate, team_slug: "team-a", opponent_team_slug: opponent.slug,
                           game_slug: game.slug, expected_score: 20.0, week: number, status: "pending")
    end
  end

  def count_queries(&block)
    count = 0
    counter = ->(_name, _start, _finish, _id, payload) do
      count += 1 unless payload[:name].to_s.in?(["SCHEMA", "TRANSACTION"]) || payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end

  test "an unknown slate redirects rather than 500ing" do
    get benchmarks_path(slug: "no-such-slate")

    assert_redirected_to root_path
  end
end
