class AddWeekToSlateMatchups < ActiveRecord::Migration[8.1]
  # A span slate ("NFL 2026 Weeks 1-3") holds three games per team copied from
  # three weekly slates. The week lived on the SOURCE slate, so once copied the
  # matchup no longer knew which week it belonged to — and the board labels each
  # opponent by week ("Week 1 / Week 2 / Week 3").
  #
  # Carrying the week on the matchup keeps that label honest instead of falling
  # back to a positional guess. Nullable: World Cup matchups have no NFL week.
  def up
    add_column :slate_matchups, :week, :integer
    add_index :slate_matchups, [:slate_id, :week]

    # Backfill from the owning slate, which already carries its week.
    execute <<~SQL
      UPDATE slate_matchups
      SET week = slates.week
      FROM slates
      WHERE slate_matchups.slate_id = slates.id
        AND slates.week IS NOT NULL
    SQL
  end

  def down
    remove_column :slate_matchups, :week
  end
end
