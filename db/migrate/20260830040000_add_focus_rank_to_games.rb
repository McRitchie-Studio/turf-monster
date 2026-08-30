# WHICH GAME THE BOARD OPENS ON, decided by an operator rather than by the
# clock alone.
#
# On a Sunday with nine kickoffs at once, "the earliest one" is a coin toss and
# every automatic rule that reaches for the marquee game (best record? closest
# spread? most entrants?) is a guess dressed as a heuristic. The operator
# already knows which game is the one — so this column is where they say it,
# and Live::FocusGame reads it as the tiebreak inside whichever set of games is
# eligible at that moment.
#
# A POSITION IN ONE LIST, enforced by the index, not by hope. The partial unique
# index is scoped to the season SLOT (year + season type + week) because that is
# the set the board renders and reorders as a whole, and it excludes NULL so a
# week nobody has dragged carries no ranks at all — which the ladder reads as
# kickoff order, the same order the board seeds the list in. Two games cannot
# share position 2 in the same week; the same position in a DIFFERENT week is
# exactly what an operator sets every Sunday.
class AddFocusRankToGames < ActiveRecord::Migration[8.1]
  def change
    add_column :games, :focus_rank, :integer

    add_index :games, [:season_year, :season_type, :week, :focus_rank],
              unique: true,
              where: "focus_rank IS NOT NULL",
              name: "index_games_on_focus_rank_per_slot"
  end
end
