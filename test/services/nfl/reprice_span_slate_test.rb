require "test_helper"

# Nfl::RepriceSpanSlate moves an EXISTING span slate onto the two-line rule in
# place. It is a money tool, so what it refuses matters as much as what it
# writes: dry run by default, never a started slate, and never a paid pick
# without the operator's explicit say-so.
class Nfl::RepriceSpanSlateTest < ActiveSupport::TestCase
  setup do
    @slate = Slate.create!(name: "NFL 2026 Weeks 4-6", slug: "nfl-2026-weeks-4-6")
    @kickoff = 10.days.from_now
    # Frozen the OLD way — ranked on the summed total, one line: the bye team
    # (54.0 total, 27.0 a game) sank to the bottom at 2.0x.
    add_games!("full-a", [26.0, 26.0, 26.0], rank: 1, turf: 1.0)  # 78 total, 26/game
    add_games!("full-b", [20.0, 20.0, 20.0], rank: 2, turf: 1.5)  # 60 total, 20/game
    add_games!("bye-c", [27.0, 27.0], rank: 3, turf: 2.0)         # 54 total, 27/game
  end

  def team!(slug)
    Team.find_or_create_by!(slug: slug) { |team| team.name = slug.titleize }
  end

  def add_games!(team_slug, scores, rank:, turf:)
    team!(team_slug)
    scores.each_with_index do |score, index|
      opponent = team!("opp-#{team_slug}-#{index}").slug
      game = Game.create!(slug: "#{team_slug}-vs-#{opponent}", home_team_slug: team_slug,
                          away_team_slug: opponent, status: "scheduled", kickoff_at: @kickoff + index.days)
      SlateMatchup.create!(slate: @slate, team_slug: team_slug, opponent_team_slug: opponent,
                           game_slug: game.slug, expected_score: score, week: 4 + index,
                           status: "pending", rank: rank, turf_score: turf)
    end
  end

  def prices
    @slate.slate_matchups.group(:team_slug).pluck(:team_slug, "MIN(rank)", "MIN(turf_score)", "MAX(turf_score)")
          .to_h { |slug, rank, low, high| [slug, [rank, low.to_f, high.to_f]] }
  end

  def pick!(team_slug, status)
    user = { active: users(:alex), cart: users(:jordan), complete: users(:sam) }.fetch(status)
    entry = Entry.create!(user: user, contest: contests(:one), status: status)
    Selection.create!(entry: entry, slate_matchup: @slate.slate_matchups.find_by(team_slug: team_slug))
  end

  test "a dry run reports the two-line prices and writes nothing" do
    before = prices

    result = Nfl::RepriceSpanSlate.call(slate: @slate)

    assert_not result.applied
    assert_nil result.refusal
    assert_equal before, prices, "a dry run must not touch a single row"
    bye = result.changes.find { |change| change.team_slug == "bye-c" }
    assert_equal [3, 1, 2.0, 1.5], [bye.old_rank, bye.new_rank, bye.old_turf_score.to_f, bye.new_turf_score]
    assert_equal 2, bye.games
  end

  test "apply writes every row of every team onto its line" do
    result = Nfl::RepriceSpanSlate.call(slate: @slate, apply: true)

    assert result.applied
    # Per game: bye-c 27, full-a 26, full-b 20. Three teams, so the full line
    # steps 1.0 / 1.5 / 2.0 and the bye line is that x1.5.
    assert_equal({ "bye-c" => [1, 1.5, 1.5], "full-a" => [2, 1.5, 1.5], "full-b" => [3, 2.0, 2.0] }, prices)
  end

  test "an unpaid pick never blocks — nobody paid that price" do
    pick!("bye-c", :cart)

    result = Nfl::RepriceSpanSlate.call(slate: @slate, apply: true)

    assert result.applied
    assert_equal 1, result.changes.find { |change| change.team_slug == "bye-c" }.unpaid_picks
  end

  test "a paid pick refuses the write and says why" do
    pick!("full-b", :active)
    before = prices

    result = Nfl::RepriceSpanSlate.call(slate: @slate, apply: true)

    assert_not result.applied
    assert_match(/1 paid pick\b/, result.refusal)
    assert_equal before, prices
  end

  test "a completed entry counts as paid too" do
    pick!("full-a", :complete)

    assert_match(/paid pick/, Nfl::RepriceSpanSlate.call(slate: @slate, apply: true).refusal)
  end

  test "the operator can reprice paid picks by saying so" do
    pick!("full-b", :active)

    result = Nfl::RepriceSpanSlate.call(slate: @slate, apply: true, reprice_paid_picks: true)

    assert result.applied
    assert_equal 1, result.paid_picks
    assert_equal [3, 2.0, 2.0], prices["full-b"]
  end

  test "a started slate is never repriced, even with the override" do
    result = Nfl::RepriceSpanSlate.call(slate: @slate, apply: true, reprice_paid_picks: true,
                                        now: @kickoff + 1.minute)

    assert_not result.applied
    assert_match(/kicked off/, result.refusal)
    assert_equal [3, 2.0, 2.0], prices["bye-c"]
  end

  test "a slate already on its lines has nothing to write" do
    Nfl::RepriceSpanSlate.call(slate: @slate, apply: true)

    again = Nfl::RepriceSpanSlate.call(slate: @slate, apply: true)

    assert_not again.applied
    assert_empty again.changed
  end
end
