require "test_helper"

# The slate page must price a team the way settlement prices it. Rendering from
# a live ranking while Selection#compute_points! settles from the STORED
# turf_score let the two disagree — most visibly on World Cup slates, which
# carry no expected_score and so rendered exactly inverted.
class SlateRenderMatchesSettlementTest < ActiveSupport::TestCase
  setup do
    @slate = Slate.create!(name: "Render Parity Slate", slug: "render-parity-slate")
  end

  def add!(team_slug, expected:, rank: nil, turf_score: nil, game_slug: nil)
    SlateMatchup.create!(
      slate: @slate, team_slug: team_slug, opponent_team_slug: "team-f",
      game_slug: game_slug, expected_score: expected,
      rank: rank, turf_score: turf_score, status: "pending"
    )
  end

  test "team_rows reports the STORED multiplier, which is what settles" do
    matchup = add!("team-a", expected: 25.0, rank: 4, turf_score: 2.7)

    row = @slate.team_rows.find { |r| r.team_slug == "team-a" }

    assert_equal 2.7, row.turf_score.to_f
    assert_equal 4, row.rank
    # The number rendered is the number Selection#compute_points! multiplies by.
    assert_equal matchup.turf_score.to_f, row.turf_score.to_f
  end

  test "a stored ranking is NOT overridden by a recomputed one" do
    # Stored order deliberately contradicts what expected points alone imply:
    # team-b has the LOWER expectation but the BETTER stored rank (an operator
    # override, or a World Cup slate ranked by hand).
    add!("team-a", expected: 30.0, rank: 2, turf_score: 3.0)
    add!("team-b", expected: 10.0, rank: 1, turf_score: 1.0)

    assert_equal %w[team-b team-a], @slate.team_rows.map(&:team_slug)
  end

  test "World Cup slates with no expected points render in stored order" do
    # No expected_score at all — a live ranking ties every team and falls
    # through to alphabetical, rendering the favourite as the 3.0x longshot.
    add!("team-c", expected: nil, rank: 1, turf_score: 1.0)
    add!("team-a", expected: nil, rank: 2, turf_score: 2.0)
    add!("team-b", expected: nil, rank: 3, turf_score: 3.0)

    rows = @slate.team_rows

    assert_equal %w[team-c team-a team-b], rows.map(&:team_slug),
                 "stored rank must win over the alphabetical order a tie would produce"
    assert_equal [1.0, 2.0, 3.0], rows.map { |r| r.turf_score.to_f }
  end

  test "an admin reorder is visible on the page it was saved from" do
    add!("team-a", expected: 30.0, rank: 1, turf_score: 1.0)
    add!("team-b", expected: 10.0, rank: 2, turf_score: 3.0)

    # Operator drags team-b above team-a; update_rankings writes stored values.
    @slate.slate_matchups.where(team_slug: "team-b").update_all(rank: 1, turf_score: 1.0)
    @slate.slate_matchups.where(team_slug: "team-a").update_all(rank: 2, turf_score: 3.0)

    assert_equal %w[team-b team-a], @slate.reload.team_rows.map(&:team_slug),
                 "the reorder was write-only when the page recomputed instead of reading stored"
  end

  test "an unranked slate still renders, falling back to a computed order" do
    add!("team-a", expected: 10.0)
    add!("team-b", expected: 30.0)

    rows = @slate.team_rows

    assert_equal %w[team-b team-a], rows.map(&:team_slug)
    assert_equal 1.0, rows.first.turf_score
  end
end
