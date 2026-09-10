# `games.slug` is built as "<home-team>-vs-<away-team>"
# (`Nfl::CacheExpectedTeamTotals#ensure_game!`), which silently assumes two
# teams meet at most once at a given venue per season. Preseason breaks that
# assumption, and not hypothetically — diffing the real 2026 ESPN schedule (49
# preseason games against 272 regular-season games) turns up two collisions:
#
#   los-angeles-chargers-vs-san-francisco-49ers   pre wk3 Aug 21  /  reg wk15 Dec 18
#   seattle-seahawks-vs-dallas-cowboys            pre wk2 Aug 16  /  reg wk13 Dec  8
#
# So importing preseason scores under the current slug scheme would write
# August exhibition results onto the very rows the December games need. That is
# a silent, money-affecting corruption, and it is what these columns prevent.
#
# `external_id` — ESPN's own event id ("401873298"). This becomes the
# IMPORTER'S identity for a game, and it is collision-proof by construction:
# distinct games have distinct event ids no matter who is playing whom or when.
# Every lookup on the polling path goes through this column, never the slug.
# Unique + partial, for the same reason as `goals.external_id` — games created
# by the odds CSV or the World Cup seed have no upstream id and must be allowed
# to share NULL.
#
# `season_type` / `season_year` / `week` — the game's place in the calendar,
# mirroring ESPN's own vocabulary (season_type 1 = preseason, 2 = regular,
# 3 = postseason). Two jobs: they disambiguate a slug that would otherwise
# collide, and they let the live scoreboard label and group games without a
# second network call. Nullable throughout because every game that exists today
# predates the feed and genuinely does not know its own season type; code must
# read them as "unknown", never as "preseason".
#
# `period` / `clock` / `status_detail` — the game's live CLOCK STATE, which
# no column holds today because until now a game only ever went from scheduled
# to a final score. The scoreboard renders "Q3 8:42" straight from these, so a
# broadcast-replaced board needs no network call to stay truthful.
# `status_detail` is ESPN's own shortDetail ("Final", "Q3 8:42", "Halftime")
# and is what the card actually prints; period and clock are kept structured
# alongside it so sorting and logic never have to parse a display string.
#
# Deliberately NOT changing the slug format for regular-season games: those
# slugs are already referenced by live SlateMatchup rows, and two regular-season
# meetings of the same teams at the same venue cannot occur. Only non-regular
# games need a suffix, which `Game#name_slug` now supplies.
class AddSeasonIdentityToGames < ActiveRecord::Migration[8.0]
  def change
    add_column :games, :external_id, :string
    add_column :games, :season_type, :integer
    add_column :games, :season_year, :integer
    add_column :games, :week, :integer
    add_column :games, :period, :integer
    add_column :games, :clock, :string
    add_column :games, :status_detail, :string

    add_index :games, :external_id,
              unique: true,
              where: "external_id IS NOT NULL",
              name: "index_games_on_external_id_when_present"

    # The live scoreboard's ONE query: "every game in this season/type/week,
    # in kickoff order". Leading on the three filter columns and trailing on
    # the sort key lets that render straight off the index.
    add_index :games, [:season_year, :season_type, :week, :kickoff_at],
              name: "index_games_on_season_slot"
  end
end
