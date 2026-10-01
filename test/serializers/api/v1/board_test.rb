require "test_helper"

# [unit] Api::V1::Board: the pickable team rows of a contest, and one pick.
class Api::V1::BoardTest < ActiveSupport::TestCase
  include SpanContestBuilder
  include AgentApiTestSupport

  setup { @contest = contests(:one) }

  def board(contest_locked: false)
    Api::V1::Board.new(Contest.find(@contest.id), contest_locked: contest_locked)
  end

  def team(rows, slug)
    rows.find { |row| row[:team][:slug] == slug }
  end

  test "a single-week contest offers every matchup, best rank first" do
    rows = board.teams

    assert_equal fixture_matchups.map(&:id), rows.map { |row| row[:matchup_id] }
    assert_equal [1, 2, 3, 4, 5, 6], rows.map { |row| row[:rank] }

    first = rows.first
    assert_equal({ slug: "team-a", name: "Team A", short_name: "TMA" }, first[:team])
    assert_equal 1.0, first[:turf_score]
    assert_kind_of Float, first[:turf_score]
    assert_equal false, first[:locked]
    assert_equal 1, first[:games_count]
    assert_equal [], first[:bye_weeks]
    assert_equal "team-b", first[:games].first[:opponent][:slug]
  end

  test "a team with no result and no projection reports null, not zero" do
    row = board.teams.first

    assert_nil row[:team_score]
    assert_nil row[:expected_team_score]
    assert_nil row[:games].first[:team_score]
    assert_nil row[:games].first[:kickoff_at]
  end

  test "a shutout is zero, which is a different answer from no result" do
    slate_matchups(:m1).update!(goals: 0)

    assert_equal 0, board.teams.first[:team_score]
  end

  test "a span contest offers one row per team, anchored on its first game" do
    build_span_contest!(@contest)
    rows = board.teams

    assert_equal 6, rows.size
    assert_equal @contest.reload.pickable_matchup_ids.sort, rows.map { |row| row[:matchup_id] }.sort
    assert_equal span_row(@contest, "team-a", week: 1).id, team(rows, "team-a")[:matchup_id]

    games = team(rows, "team-a")[:games]
    assert_equal [1, 2], games.map { |game| game[:week] }
    assert_equal %w[team-b team-c], games.map { |game| game[:opponent][:slug] }
    assert_equal [true, true], games.map { |game| game[:home] }
    assert_equal [true, false], team(rows, "team-c")[:games].map { |game| game[:home] }
    assert_equal 40.0, team(rows, "team-a")[:expected_team_score], "summed over both games"
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, games.first[:kickoff_at])
  end

  test "a team with a bye in the span says which week it sits out" do
    build_span_contest!(@contest)
    span_row(@contest, "team-a", week: 2).destroy!
    rows = board.teams

    assert_equal [2], team(rows, "team-a")[:bye_weeks]
    assert_equal 1, team(rows, "team-a")[:games_count]
    assert_equal [], team(rows, "team-b")[:bye_weeks]
  end

  test "a span team's score is summed over the weeks that have a result" do
    build_span_contest!(@contest)
    span_row(@contest, "team-a", week: 1).update!(goals: 21)
    assert_equal 21, team(board.teams, "team-a")[:team_score]

    span_row(@contest, "team-a", week: 2).update!(goals: 10)
    row = team(board.teams, "team-a")
    assert_equal 31, row[:team_score]
    assert_equal [21, 10], row[:games].map { |game| game[:team_score] }
  end

  test "a team is locked once its first game kicks off, while its later game has not started" do
    build_span_contest!(@contest, week_one_kickoff: 1.hour.ago)
    row = team(board.teams, "team-a")

    assert_equal true, row[:locked]
    assert_equal [true, false], row[:games].map { |game| game[:started] }
  end

  test "every team is locked once the contest locks, whatever its own kickoff" do
    build_span_contest!(@contest)

    assert_equal [false], board.teams.map { |row| row[:locked] }.uniq
    assert_equal [true], board(contest_locked: true).teams.map { |row| row[:locked] }.uniq
  end

  test "a pick is its team row plus the points it has earned" do
    entry = enter!(users(:sam), @contest, [slate_matchups(:m2)])
    selection = entry.selections.first

    assert_nil board.pick(selection)[:points], "no result yet"

    slate_matchups(:m2).update!(goals: 3)
    selection.reload.compute_points!
    pick = board.pick(selection.reload)

    assert_equal slate_matchups(:m2).id, pick[:matchup_id]
    assert_equal 3, pick[:team_score]
    assert_equal 1.2, pick[:turf_score]
    assert_in_delta 3.6, pick[:points], 0.001
  end

  test "building the board and reading every team does not query per team" do
    build_span_contest!(@contest)

    queries = count_queries { board.teams }

    assert_operator queries, :<=, 9, "two loads of the slate (rows + teams, opponents, games), whatever its size"
  end
end
