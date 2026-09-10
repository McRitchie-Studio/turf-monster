class RemodelTeamColors < ActiveRecord::Migration[8.1]
  # Recast the brand-color model. The old (primary, secondary, alt_light,
  # alt_dark, text_light) named colors by ROLE; the new model names them by
  # intrinsic LIGHTNESS (dark/light, each with an alt) and adds an explicit
  # color_disposition that says which color is the card field. See
  # Nfl::TeamPalette for the values, re-applied by `nfl:recolor`.
  def up
    rename_column :teams, :color_primary,    :color_dark
    rename_column :teams, :color_secondary,  :color_light
    rename_column :teams, :color_alt_dark,   :color_dark_alt
    rename_column :teams, :color_alt_light,  :color_light_alt

    add_column :teams, :color_disposition, :string, null: false, default: "dark"
    # Seed disposition from the retired flag; the palette re-apply sets the
    # authoritative value for every NFL team right after this migration.
    execute "UPDATE teams SET color_disposition = 'light' WHERE color_text_light = true"
    remove_column :teams, :color_text_light
  end

  def down
    add_column :teams, :color_text_light, :boolean, default: false
    execute "UPDATE teams SET color_text_light = true WHERE color_disposition = 'light'"
    remove_column :teams, :color_disposition

    rename_column :teams, :color_light_alt, :color_alt_light
    rename_column :teams, :color_dark_alt,  :color_alt_dark
    rename_column :teams, :color_light,     :color_secondary
    rename_column :teams, :color_dark,      :color_primary
  end
end
