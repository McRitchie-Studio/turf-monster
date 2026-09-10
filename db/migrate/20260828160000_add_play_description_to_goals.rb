# WHAT the scoring play WAS, in words a reader recognises: "22 yard receiving
# TD", "8 yard rushing TD", "53 yard field goal".
#
# ESPN says it only inside the play prose, in the same sentence that names the
# scorer — "Ja'Marr Chase 12 Yd pass from Joe Burrow (Evan McPherson Kick)".
# Parsed once at write time and stored, rather than re-derived on every render
# of a row that never changes.
#
# Nullable throughout: a hand-recorded goal has no prose to parse, and the card
# simply drops the line rather than inventing one.
class AddPlayDescriptionToGoals < ActiveRecord::Migration[8.1]
  def change
    add_column :goals, :play_description, :string
  end
end
