# Move this app's geo policy into the engine's table.
#
# The rows are the LEGAL exclusion list — the states this app may not operate in
# — so they are copied rather than re-seeded: production's list was edited by an
# operator at /admin/geo and is not necessarily the seeded default.
#
# One shape change on the way across. The old column held bare state codes
# (["WA", "ID"]); the engine stores REGION TOKENS (["US-WA", "US-ID"]), because
# "CA" is California and Canada and a bare code cannot say which. Studio::GeoSetting
# normalizes bare input on write anyway, but this migration writes the canonical
# form directly so the row is correct even if it is never saved again.
#
# Reversible: `down` rebuilds geo_settings and copies the list back in its old
# bare shape, so a rollback lands on a working app rather than an empty gate.
class MoveGeoSettingsIntoTheEngineTable < ActiveRecord::Migration[8.0]
  HOME = "US".freeze

  def up
    return unless table_exists?(:geo_settings)

    rows(:geo_settings).each do |row|
      next if select_value("SELECT 1 FROM studio_geo_settings WHERE app_name = #{quote(row['app_name'])}")

      subdivisions = list(row["banned_states"]).map { |code| "#{HOME}-#{code.to_s.strip.upcase}" }
      insert_row(:studio_geo_settings, row, "banned_subdivisions" => subdivisions)
    end

    drop_table :geo_settings
  end

  def down
    create_table :geo_settings do |t|
      t.string   :app_name, null: false
      t.jsonb    :banned_states, default: []
      t.boolean  :enabled, null: false, default: false
      t.string   :slug
      t.timestamps
    end
    add_index :geo_settings, :app_name, unique: true
    add_index :geo_settings, :slug, unique: true

    rows(:studio_geo_settings).each do |row|
      states = list(row["banned_subdivisions"])
               .filter_map { |token| token.to_s.split("-", 2).last if token.to_s.start_with?("#{HOME}-") }
      insert_row(:geo_settings, row, "banned_states" => states)
    end
  end

  private

  def rows(table)
    select_all("SELECT * FROM #{table}").to_a
  end

  # jsonb comes back either already parsed or as a JSON string, depending on the
  # adapter and how the column was written. Handle both rather than guessing.
  def list(value)
    return Array(value) unless value.is_a?(String)

    JSON.parse(value)
  rescue JSON::ParserError
    []
  end

  def insert_row(table, row, list_column)
    name, values = list_column.first
    execute(<<~SQL)
      INSERT INTO #{table} (app_name, enabled, #{name}, slug, created_at, updated_at)
      VALUES (
        #{quote(row['app_name'])},
        #{quote(row['enabled'])},
        #{quote(values.to_json)},
        #{quote(row['slug'])},
        #{quote(row['created_at'] || Time.current)},
        #{quote(row['updated_at'] || Time.current)}
      )
    SQL
  end

  def quote(value)
    connection.quote(value)
  end

  def select_value(sql)
    connection.select_value(sql)
  end

  def select_all(sql)
    connection.select_all(sql)
  end
end
