class AddAltColorsToTeams < ActiveRecord::Migration[8.1]
  # Two more brand-color slots per team. With color_primary (card background)
  # and color_secondary (the mascot accent), these capture the team's light and
  # dark neutrals (usually white and black) so the /teams palette is complete.
  def change
    add_column :teams, :color_alt_light, :string
    add_column :teams, :color_alt_dark, :string
  end
end
