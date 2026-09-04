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
         SET week = CAST(substring(name FROM '[Ww]eek ([0-9]+)') AS INTEGER)
       WHERE season_type = #{PRESEASON}
         AND week IS NULL
         AND name ~* 'week [0-9]+'
    SQL
  end

  # A TRUE INVERSE, because `up` mutated more than the schema.
  #
  # `up` writes `week` on preseason slates (NULL -> 4). Dropping only the column
  # would leave those rows carrying a week with NOTHING left to disambiguate
  # them — and the reverted BuildSpanSlate selects by week + year + sport and
  # keeps the LAST row per week, which `.order(:id)` makes the preseason row.
  # A regular-season "Weeks 2-4" contest would then be assembled from exhibition
  # matchups: the exact failure the old `week = nil` workaround prevented, made
  # deterministic rather than merely possible.
  #
  # That is not a theoretical rollback either. The release phase runs
  # `db:migrate`, which never reverses; the real incident lever is `heroku
  # rollback`, which leaves the column in place while the CODE reverts — so the
  # reverted code has no season_type scope and reads the backfilled week anyway.
  # This restores the only thing it can: the state `up` found.
  #
  # Exactly inverse by construction — `up` wrote `week` only where it was NULL
  # AND season_type is preseason, so nulling that same set restores it.
  def down
    execute "UPDATE slates SET week = NULL WHERE season_type = #{PRESEASON}"
    remove_index :slates, name: "index_slates_on_season_slot"
    remove_column :slates, :season_type
  end
end
