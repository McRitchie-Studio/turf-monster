# The DOWN-AND-DISTANCE STATE of a game in progress — what a broadcast puts on
# its lower third, and what the live focus rail now shows instead of a kickoff
# time the reader already read off the date above it.
#
# THREE COLUMNS, NOT ONE PARSED STRING. ESPN hands us `downDistanceText`
# ("3rd & 9") and `possessionText` ("NE 13") already composed for display, and
# the possessing team as a competitor id. Storing the two strings verbatim keeps
# us out of the business of pluralising downs and naming yard lines; storing the
# possessing team as a SLUG — not the id, which is ESPN's — lets the view name
# the team in our own vocabulary and colour it from our own palette.
#
# ALL THREE ARE NULLABLE AND ARE MEANT TO GO BACK TO NULL. A scheduled game has
# no situation and neither does a final one; ESPN simply omits the block, and
# the poll cycle writes the nil through rather than leaving the last snap of the
# fourth quarter frozen on a card that says FINAL.
class AddSituationToGames < ActiveRecord::Migration[8.1]
  def change
    add_column :games, :down_distance, :string
    add_column :games, :possession_text, :string
    add_column :games, :possession_team_slug, :string
  end
end
