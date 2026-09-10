# Rename the misnamed `dk_goals_expectation` column to `expected_score`.
#
# The column holds a team's expected SCORE for the slate — NFL points, soccer
# goals — and never came from DraftKings, so the old name was a triple misnomer.
# This is a pure, value-preserving rename: the data, the ranking it feeds, and
# the frozen turf_score settlement multiplies by are all unchanged. rename_column
# is auto-reversible, so `down` restores the old name.
class RenameDkGoalsExpectationToExpectedScore < ActiveRecord::Migration[8.1]
  def change
    rename_column :slate_matchups, :dk_goals_expectation, :expected_score
  end
end
