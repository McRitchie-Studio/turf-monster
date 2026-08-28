# Two active NFL players can share a name. Seven do in the 2026 league —
# including Justin Jefferson, who is both a Vikings receiver and a Browns
# linebacker.
#
# Person slugs derive from the name, so the second of a pair collided with the
# first and the importer attached to the wrong record: the Vikings receiver was
# silently overwritten and lost. This column lets a genuine namesake carry a
# stable, deterministic slug suffix ("justin-jefferson-1075") instead. It is
# NULL for everyone else, which is almost everyone.
class AddDisambiguatorToPeople < ActiveRecord::Migration[8.1]
  def change
    add_column :people, :disambiguator, :string
  end
end
