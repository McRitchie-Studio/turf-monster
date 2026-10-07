# This migration comes from studio_engine (originally 20261006120002)
# The engine owns the shape of `theme_settings`: ThemeSetting and /admin/theme
# write the columns below on every host.
#
# `slug` is the column this migration exists for. ThemeSetting includes
# Sluggable, whose before_save writes `slug` on every save, and the setup doc's
# hand-copied migration omitted it, so a theme save raises on any host built
# from that doc (cyvasse, mcritchie-industries and moms-app when this shipped).
# The slug is "theme-<app_name>", derived on save; existing rows keep a NULL
# slug until their next save, and nothing looks a theme up by slug.
#
# A baseline, not a rebuild:
#
#   - no table: create it in the engine's shape, with its unique app_name index;
#   - a table: add any engine column it lacks, as a plain nullable column, and
#     touch nothing else. No column is changed or dropped, no constraint is
#     tightened and no index is added.
#
# Studio::HostSchema checks the same columns at boot.
class EnsureThemeSettingsTable < ActiveRecord::Migration[7.2]
  def up
    unless table_exists?(:theme_settings)
      create_table :theme_settings do |t|
        t.string :app_name, null: false
        t.string :slug
        t.string :primary
        t.string :dark
        t.string :light
        t.string :accent1
        t.string :accent2
        t.string :warning
        t.string :danger

        t.timestamps
      end

      add_index :theme_settings, :app_name, unique: true
      return
    end

    add_column :theme_settings, :app_name,   :string,   if_not_exists: true
    add_column :theme_settings, :slug,       :string,   if_not_exists: true
    add_column :theme_settings, :primary,    :string,   if_not_exists: true
    add_column :theme_settings, :dark,       :string,   if_not_exists: true
    add_column :theme_settings, :light,      :string,   if_not_exists: true
    add_column :theme_settings, :accent1,    :string,   if_not_exists: true
    add_column :theme_settings, :accent2,    :string,   if_not_exists: true
    add_column :theme_settings, :warning,    :string,   if_not_exists: true
    add_column :theme_settings, :danger,     :string,   if_not_exists: true
    add_column :theme_settings, :created_at, :datetime, if_not_exists: true
    add_column :theme_settings, :updated_at, :datetime, if_not_exists: true
  end

  # The migration records nothing about whether it created the table or found
  # it, so a down cannot tell the engine's table from the host's own theme. It
  # refuses instead.
  def down
    return unless table_exists?(:theme_settings)

    raise ActiveRecord::IrreversibleMigration,
          "EnsureThemeSettingsTable cannot tell whether it created theme_settings or found the host's own; " \
          "drop the table or the slug column by hand if this app truly owns neither."
  end
end
