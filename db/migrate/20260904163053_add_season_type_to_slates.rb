class AddSeasonTypeToSlates < ActiveRecord::Migration[8.1]
  # WHICH SEASON a weekly slate belongs to, as a column.
  #
  # Week numbers are NOT unique within a year: NFL preseason week 3 and regular
  # week 3 both exist, and `Nfl::BuildSpanSlate` finds its source slates by
  # `week` + `year` + `sport`. Asked for a preseason 3-4 span it would have
  # silently returned the REGULAR weeks — unplayed games, sold as a contest.
  #
  # AN INTEGER, IN ESPN'S CODES, BECAUSE `games` ALREADY SPEAKS THAT LANGUAGE.
  # `games.season_type` is an integer on exactly this scale (see
  # Game.in_season_slot and Nfl::BuildPreseasonSlate::PRESEASON = 1). Writing
  # the slate side as "preseason"/"regular" strings would put two vocabularies
  # for one concept in adjacent tables, and the failure that follows is silent:
  # `Slate.where(season_type: game.season_type)` matches nothing, forever, with
  # no error to read.
  #
  #   1 = preseason   2 = regular season   3 = postseason
  #
  # A column rather than another regex against the name, because that is the
  # direction this table already moved: BuildSpanSlate's own comment records
  # that scoping by `year` + `sport` COLUMNS replaced a LIKE on the name
  # precisely so a rename could not defeat it.
  PRESEASON = 1
  REGULAR = 2

  def up
    add_column :slates, :season_type, :integer, null: false, default: REGULAR
    add_index :slates, [:sport, :year, :season_type, :week], name: "index_slates_on_season_slot"

    # Backfilled from the name because the name is the only record we have of
    # it today — but only ONCE, here. After this, the column is the truth.
    execute "UPDATE slates SET season_type = #{PRESEASON} WHERE name ILIKE '%preseason%'"

    # A preseason slate carries week: nil today, so it could never be found as a
    # span source. Recover the number from the name it is already displaying.
    execute <<~SQL
      UPDATE slates
         SET week = CAST(substring(name FROM 'Week ([0-9]+)') AS INTEGER)
       WHERE season_type = #{PRESEASON}
         AND week IS NULL
         AND name ~ 'Week [0-9]+'
    SQL
  end

  def down
    remove_index :slates, name: "index_slates_on_season_slot"
    remove_column :slates, :season_type
  end
end
