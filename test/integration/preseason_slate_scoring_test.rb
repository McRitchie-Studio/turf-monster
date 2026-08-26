require "test_helper"

# [integration] The chain a preseason testing slate exists to close, end to end:
# a scoring play lands and an entry's standing moves.
#
# Every link is real — no stubs. This is the half of the live-scoring pipeline
# that a preseason week cannot exercise without a slate, because the poller
# writes Goals into games no contest points at and every report line reads
# "(0 contests)" while the board looks perfect.
class PreseasonSlateScoringTest < ActionDispatch::IntegrationTest
  setup do
    @home = teams(:team_a)
    @away = teams(:team_b)
    [@away, teams(:team_c), teams(:team_d)].each { |t| t.update!(league: "nfl", sport: "football") }
    @game = Game.create!(
      home_team_slug: @home.slug, away_team_slug: @away.slug,
      season_year: 2026, season_type: 1, week: 4,
      kickoff_at: 1.hour.ago, status: "in_progress"
    )
    @result = Nfl::BuildPreseasonSlate.call(year: 2026, week: 4)
    @matchup = @result.matchups.find { |m| m.team_slug == @home.slug }
  end

  test "a touchdown moves the entry that picked that team" do
    entry = entry_picking(@matchup)
    assert_equal 0, entry.score.to_i

    @game.goals.create!(team_slug: @home.slug, points: 6, scoring_type: "touchdown")

    assert_equal 6, @matchup.reload.goals, "the matchup must carry the game's summed points"
    expected = 6 * @matchup.turf_score
    assert_equal expected, entry.reload.score,
      "goals x turf_score is the whole contract between the feed and a standing"
  end

  # Each scoring type is worth what the rules say, all the way through — this is
  # the reason Goal carries points instead of the score counting rows.
  test "each scoring type carries its own value into the standing" do
    entry = entry_picking(@matchup)

    @game.goals.create!(team_slug: @home.slug, points: 6, scoring_type: "touchdown")
    @game.goals.create!(team_slug: @home.slug, points: 1, scoring_type: "pat")
    @game.goals.create!(team_slug: @home.slug, points: 3, scoring_type: "field_goal")

    assert_equal 10, @matchup.reload.goals
    assert_equal 10 * @matchup.turf_score, entry.reload.score
  end

  # ESPN withdraws plays when a touchdown is overturned. The standing has to
  # come back down with it, or a contest sits on points nobody scored.
  test "an overturned play takes the standing back down" do
    entry = entry_picking(@matchup)
    touchdown = @game.goals.create!(team_slug: @home.slug, points: 6, scoring_type: "touchdown")
    @game.goals.create!(team_slug: @home.slug, points: 3, scoring_type: "field_goal")
    assert_equal 9 * @matchup.turf_score, entry.reload.score

    touchdown.destroy!

    assert_equal 3, @matchup.reload.goals
    assert_equal 3 * @matchup.turf_score, entry.reload.score
  end

  test "a score by the other team leaves this entry alone" do
    entry = entry_picking(@matchup)

    @game.goals.create!(team_slug: @away.slug, points: 6, scoring_type: "touchdown")

    assert_equal 0, @matchup.reload.goals
    assert_equal 0, entry.reload.score.to_i
  end

  # The measured gap this task was opened to close: before the slate existed,
  # this count was zero and the poller reported "(0 contests)" on every line.
  test "the preseason games are covered by an open contest" do
    affected = Contest.where(
      slate_id: SlateMatchup.where(game_slug: @game.slug).pluck(:slate_id).uniq,
      status: :open
    )

    assert_equal 1, affected.count
    assert_equal 0, affected.first.entry_fee_cents
  end

  private

  def entry_picking(matchup)
    entry = @result.contest.entries.create!(user: users(:alex), status: :active)
    entry.selections.create!(slate_matchup: matchup)
    entry.reload
  end
end
