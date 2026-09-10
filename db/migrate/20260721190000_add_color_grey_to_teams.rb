class AddColorGreyToTeams < ActiveRecord::Migration[8.1]
  # A team's standard grey. First use: the OPPONENTS divider + week labels on the
  # multi-week card (see TeamColorsHelper#team_card_palette `grey`). Falls back to
  # a neutral default when a team hasn't curated one.
  def change
    add_column :teams, :color_grey, :string
  end
end
