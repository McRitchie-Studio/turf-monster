# WHO SCORED. A Goal has always known the team and the points; it has never
# known the player, because the NFL poller had nowhere to put one —
# `player_slug` belongs to the SOCCER `players` table (goal-scorer attribution
# on the World Cup board) and reusing it would have crossed two sports in one
# column.
#
# ESPN names the scorer in the play text and nowhere else:
#
#   "Ja'Marr Chase 12 Yd pass from Joe Burrow (Evan McPherson Kick)"
#   "Jordan Mason 5 Yd Rush (Will Reichard Kick)"
#   "Isaiah Rodgers 87 Yd Interception Return (Will Reichard Kick)"
#   "Will Reichard 35 Yd Field Goal"
#
# In all four shapes the SCORER LEADS THE SENTENCE — the receiver on a pass, the
# rusher on a rush, the returner on a defensive score, the kicker on a field
# goal. Measured against 235 real scoring plays from 23 games: one leading-name
# rule extracts the scorer from 100% of them.
#
# TWO COLUMNS, NOT ONE, and the split is what keeps the card honest:
#
#   scorer_name  — what the feed SAID. Always written when the text parses, so
#                  the card can name the scorer even when we hold no athlete
#                  record for them (a practice-squad call-up, a rookie signed
#                  after the roster seed).
#   scorer_slug  — the resolved `athletes.person_slug`, which is what reaches a
#                  headshot. NULL is an ordinary, expected state: name matching
#                  resolves ~90% of scorers, and the card falls back to initials
#                  for the rest exactly as the roster pages do.
#
# Storing only the slug would blank the name for the 10%; storing only the name
# would force a name lookup on every render of a row that never changes.
class AddScorerToGoals < ActiveRecord::Migration[8.1]
  def change
    add_column :goals, :scorer_name, :string
    add_column :goals, :scorer_slug, :string

    # Indexed because the reverse question — "every score by this player" — is
    # the one a player page will ask, and it is cheap to add now.
    add_index :goals, :scorer_slug
  end
end
