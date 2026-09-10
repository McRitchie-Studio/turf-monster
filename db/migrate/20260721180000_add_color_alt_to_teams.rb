class AddColorAltToTeams < ActiveRecord::Migration[8.1]
  # A fifth brand slot with no behavior yet — a parking spot for a color that
  # doesn't fit the dark/light families (e.g. the Ravens' red, which never read
  # right as a light-alt). Displayed on the /teams palette; wired to nothing.
  def change
    add_column :teams, :color_alt, :string
  end
end
