require "test_helper"

# [unit] Api::V1::Ranking is the provisional rank the API reports before a
# contest settles. It claims to be the tie rule Contest#grade! applies, so the
# second test grades a tied contest and compares.
class Api::V1::RankingTest < ActiveSupport::TestCase
  include AgentApiTestSupport

  test "tied scores share a rank and the next rank skips" do
    ranks = Api::V1::Ranking.for([[11, 2.0], [12, 5.0], [13, 5.0], [14, 0.0], [15, 2.0]])

    assert_equal({ 12 => 1, 13 => 1, 11 => 3, 15 => 3, 14 => 5 }, ranks)
    assert_equal [12, 13, 11, 15, 14], ranks.keys, "keys come back in leaderboard order: score, then id"
  end

  test "an empty contest ranks nobody" do
    assert_equal({}, Api::V1::Ranking.for([]))
    assert_equal({}, Api::V1::Ranking.for_contests([]))
  end

  test "the provisional ranks equal the ranks grade! stores" do
    contest = contests(:one)
    contest.update!(starts_at: 1.hour.ago)
    slate_matchups(:m1).update!(goals: 2) # x1.0 -> 2.0
    slate_matchups(:m2).update!(goals: 1) # x1.2 -> 1.2
    slate_matchups(:m3).update!(goals: 0) # x1.4 -> 0.0
    [[:sam, :m1], [:casey, :m1], [:sam, :m2], [:casey, :m3]].each do |user, matchup|
      enter!(users(user), contest, [slate_matchups(matchup)])
    end
    contest.score_entries!

    provisional = Api::V1::Ranking.for_contests([contest.id]).fetch(contest.id)
    assert_equal [1, 1, 3, 4, 4, 4], provisional.values, "two tied for first, one third, three tied on zero"

    contest.grade!

    stored = contest.entries.complete.pluck(:id, :rank).to_h
    assert_equal stored, provisional
  end
end
