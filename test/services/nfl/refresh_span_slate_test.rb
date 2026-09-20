require "test_helper"

# [integration] Re-reading a span's expected scores from its weekly slates and
# repricing it — the path a benchmark rebuild takes once a contest is open,
# where Nfl::BuildSpanSlate refuses to go.
class Nfl::RefreshSpanSlateTest < ActiveSupport::TestCase
  setup do
    @kickoff = 10.days.from_now
    @weekly = (4..6).to_h { |week| [week, Slate.create!(name: "NFL 2026 Week #{week}", week: week)] }
    @span = Slate.create!(name: "NFL 2026 Weeks 4-6", slug: "nfl-2026-weeks-4-6", week: 4)

    # team-a plays all three weeks; team-b has its bye in week 6.
    @scores = { ["team-a", 4] => 20.0, ["team-a", 5] => 20.0, ["team-a", 6] => 20.0,
                ["team-b", 4] => 24.0, ["team-b", 5] => 24.0 }
    @scores.each { |(team, week), score| add_game!(team, week, score) }
    reprice_now!
  end

  # One opponent per WEEK: a Game's slug is its home-vs-away pair, so reusing an
  # opponent across weeks collides on the unique index.
  OPPONENTS = { 4 => "team-c", 5 => "team-d", 6 => "team-e" }.freeze

  def add_game!(team_slug, week, score)
    opponent = OPPONENTS.fetch(week)
    game = Game.create!(slug: "#{team_slug}-vs-#{opponent}", home_team_slug: team_slug,
                        away_team_slug: opponent, status: "scheduled", kickoff_at: @kickoff + week.days)
    [@weekly.fetch(week), @span].each do |slate|
      SlateMatchup.create!(slate: slate, team_slug: team_slug, opponent_team_slug: opponent,
                           game_slug: game.slug, expected_score: score, week: week, status: "pending")
    end
  end

  # Put the span on its current prices, the way a build would leave it.
  def reprice_now!
    Nfl::RepriceSpanSlate.call(slate: @span, apply: true)
    @span.reload
  end

  def span_scores
    @span.slate_matchups.reload.to_h { |m| [[m.team_slug, m.week], m.expected_score.to_f] }
  end

  def span_prices
    @span.slate_matchups.reload.group(:team_slug).pluck(:team_slug, "MIN(rank)", "MAX(turf_score)")
         .to_h { |slug, rank, turf| [slug, [rank, turf.to_f]] }
  end

  # The market moved: team-b's week 5 game is now worth far less, which drops it
  # below team-a per game and so swaps their ranks.
  def move_the_market!
    @weekly.fetch(5).slate_matchups.find_by(team_slug: "team-b").update!(expected_score: 8.0)
  end

  test "a dry run reports the new numbers and writes neither score nor price" do
    move_the_market!
    before_scores = span_scores
    before_prices = span_prices

    result = Nfl::RefreshSpanSlate.call(slate: @span)

    assert_not result.applied
    assert_nil result.refusal
    assert_equal [["team-b", 5, 24.0, 8.0]],
                 result.updates.map { |u| [u.team_slug, u.week, u.old.to_f, u.new.to_f] }
    assert_equal before_scores, span_scores
    assert_equal before_prices, span_prices
    # The preview is the REAL reprice, rolled back — so it can say the ranks swap.
    assert_equal 1, result.reprice.changes.find { |c| c.team_slug == "team-a" }.new_rank
  end

  test "apply writes the fresh scores and the prices they earn" do
    move_the_market!

    result = Nfl::RefreshSpanSlate.call(slate: @span, apply: true)

    assert result.applied
    assert_equal 8.0, span_scores.fetch(["team-b", 5])
    # team-a now leads on points per game, so it takes rank 1 and the 1.0x floor.
    assert_equal [1, 1.0], span_prices.fetch("team-a")
    # team-b still rides the bye line: rank 2 of 2 is 2.0x, times 1.5.
    assert_equal [2, 3.0], span_prices.fetch("team-b")
  end

  test "a paid pick refuses — and the fresh scores roll back with the price" do
    move_the_market!
    before_scores = span_scores
    before_prices = span_prices
    Selection.create!(entry: Entry.create!(user: users(:alex), contest: contests(:one), status: :active),
                      slate_matchup: @span.slate_matchups.find_by(team_slug: "team-b"))

    result = Nfl::RefreshSpanSlate.call(slate: @span, apply: true)

    assert_not result.applied
    assert_match(/paid pick/, result.refusal)
    assert_equal before_prices, span_prices
    assert_equal before_scores, span_scores,
                 "fresh scores beside stale prices is a slate that contradicts itself"
  end

  test "the operator can refresh through a paid pick by naming the decision" do
    move_the_market!
    Selection.create!(entry: Entry.create!(user: users(:alex), contest: contests(:one), status: :active),
                      slate_matchup: @span.slate_matchups.find_by(team_slug: "team-b"))

    result = Nfl::RefreshSpanSlate.call(slate: @span, apply: true, reprice_paid_picks: true)

    assert result.applied
    assert_equal 8.0, span_scores.fetch(["team-b", 5])
    assert_equal [2, 3.0], span_prices.fetch("team-b")
  end

  test "a started slate is refused, scores included" do
    move_the_market!
    before = span_scores

    result = Nfl::RefreshSpanSlate.call(slate: @span, apply: true, reprice_paid_picks: true,
                                        now: @kickoff + 5.days)

    assert_match(/kicked off/, result.refusal)
    assert_equal before, span_scores
  end

  test "a game that left the weekly slate is a rebuild, and says so" do
    @weekly.fetch(6).slate_matchups.find_by(team_slug: "team-a").destroy!

    result = Nfl::RefreshSpanSlate.call(slate: @span, apply: true)

    assert_match(/no longer in the weekly slates/, result.refusal)
    assert_match(/rebuild, not a refresh/, result.refusal)
    assert_empty result.updates
  end

  test "an unchanged market changes nothing" do
    result = Nfl::RefreshSpanSlate.call(slate: @span, apply: true)

    assert_empty result.updates
    assert_nil result.refusal
  end
end
