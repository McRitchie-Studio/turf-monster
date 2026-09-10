class AddWeekToSlates < ActiveRecord::Migration[8.1]
  # One Slate is one NFL week, but until now the week number existed ONLY as a
  # substring of slates.name ("NFL 2026 Week 3") — parsed back out by regex where
  # anything needed it. A multi-week contest has to order weeks and prove they're
  # consecutive, so the week becomes a real, sortable column.
  #
  # Nullable on purpose: World Cup slates have no NFL week.
  def up
    add_column :slates, :week, :integer
    add_index :slates, :week

    # Backfill from the naming convention that Nfl::CacheExpectedTeamTotals
    # already generates ("NFL <year> Week <n>").
    execute <<~SQL
      UPDATE slates
      SET week = CAST(substring(name from 'Week ([0-9]+)') AS integer)
      WHERE name ~ 'Week [0-9]+'
    SQL
  end

  def down
    remove_column :slates, :week
  end
end
