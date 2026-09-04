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

  # The backfill rule, as a constant so a test can bind it to the model's rule
  # rather than restate it. These are two deliberately separate copies — a
  # migration must be frozen in time, and the model will keep evolving — which
  # is exactly why they must be asserted to agree. Precedent and reasoning:
  # test/models/slate_sport_year_test.rb, written after inverting a ternary
  # inside `up` backfilled 28 slates wrong and left the suite green.
  PRESEASON_NAME_SQL = "name ILIKE '%preseason%'".freeze

  def up
    add_column :slates, :season_type, :integer, null: false, default: REGULAR
    add_index :slates, [:sport, :year, :season_type, :week], name: "index_slates_on_season_slot"

    # Backfilled from the name because the name is the only record we have of
    # it today — but only ONCE, here. After this, the column is the truth.
    execute "UPDATE slates SET season_type = #{PRESEASON} WHERE #{PRESEASON_NAME_SQL}"

    # A preseason slate carries week: nil today, so it could never be found as a
    # span source. Recover the number from the name it is already displaying.
    execute <<~SQL
      UPDATE slates
         SET week = CAST(substring(name FROM '(?i)week ([0-9]+)') AS INTEGER)
       WHERE season_type = #{PRESEASON}
         AND week IS NULL
         AND name ~* 'week [0-9]+'
    SQL
  end

  # `down` RESTORES THE CONVENTION, NOT THE EXACT ROWS — and the difference is
  # worth stating rather than glossing.
  #
  # `up` writes `week` on preseason slates (NULL -> 4). Dropping only the column
  # would leave those rows carrying a week with NOTHING left to disambiguate
  # them — and the reverted BuildSpanSlate selects by week + year + sport and
  # keeps the LAST row per week, which `.order(:id)` makes the preseason row.
  # A regular-season "Weeks 2-4" contest would then be assembled from exhibition
  # matchups: the exact failure the old `week = nil` workaround prevented, made
  # deterministic rather than merely possible.
  #
  # WHAT THIS DOES NOT COVER, stated plainly because an earlier version of this
  # comment claimed otherwise:
  #
  #   * It is NOT a row-level inverse. `up` wrote `week` only where it was NULL;
  #     `down` nulls it on every preseason slate, including any created AFTER
  #     the migration (BuildPreseasonSlate now sets a real week). Those rows did
  #     not exist for `up` to skip, and returning them to the pre-migration
  #     convention is the only coherent answer — but it is a convention restored,
  #     not a snapshot replayed.
  #   * It does NOT run on `heroku rollback`. That is the real incident lever,
  #     and it reverts the SLUG while leaving the database alone — no `down`, no
  #     migration, column and backfill both still in place, and the reverted code
  #     with no season_type scope reading the week anyway. This method cannot
  #     help there. Only `rails db:rollback` reaches it.
  def down
    execute "UPDATE slates SET week = NULL WHERE season_type = #{PRESEASON}"
    remove_index :slates, name: "index_slates_on_season_slot"
    remove_column :slates, :season_type
  end
end
