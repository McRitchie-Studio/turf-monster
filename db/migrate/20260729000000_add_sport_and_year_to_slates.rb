# Scaling the slate registry. `slates` carried neither `sport` nor `year`, so both
# were parsed out of the NAME on every read — sport by regex (`Slate#sport`), year by a
# `\b(20\d{2})\b` scan (`Slate#season_year`), and span lookups by `name LIKE 'NFL <y> %'`.
# That works only while names follow one convention and one sport owns the `NFL` token.
#
# PRICING-ADJACENT, so the backfill is written to be provably value-preserving.
# `sport` selects the multiplier curve (`SlateMatchup.turf_score_for(..., sport:)`).
# That curve's output is PERSISTED onto `slate_matchups.turf_score` at rank time and
# settlement reads the stored column, so a flipped sport cannot re-price an EXISTING
# pick — it corrupts the next ranking instead. The backfill therefore derives each value
# with the SAME rules the readers used, so no existing row changes meaning: the columns
# record what the names already implied.
#
# Only ONE index: [year, week], which is how spans are looked up. A sport index would be
# dead weight — two distinct values across a table holding tens of rows, so no planner
# would ever choose it.
#
# Nullable on purpose: the model keeps the name-derived fallback for any row this misses
# (and for rows created by older code paths mid-deploy), so a null is degraded, never
# wrong. `slates-sport-year` demotes the regexes to that fallback rather than deleting
# them.
class AddSportAndYearToSlates < ActiveRecord::Migration[8.1]
  # Mirrors Slate#sport as it stood before this migration: the NFL token, or a week
  # marker, means football; everything else is World Cup. Inlined rather than calling
  # the model so a later model edit cannot retroactively change what this backfilled.
  NFL_NAME = /\bnfl\b|\bweeks?\s+\d/i
  # Mirrors Slate#season_year: a bounded 4-digit 20xx, so a stray week number can never
  # read as a year.
  YEAR_IN_NAME = /\b(20\d{2})\b/

  # The derivation, as CALLABLE methods rather than expressions inlined in `up`.
  # `up` calls these and so does the drift test, so the test executes the real thing
  # instead of re-implementing it. An earlier version compared only the CONSTANTS,
  # which let an inverted ternary in `up` backfill all 28 slates wrong while the suite
  # stayed green — the constant matched, the behaviour did not.
  def self.sport_for(name)
    name.to_s.downcase.match?(NFL_NAME) ? "nfl" : "fifa"
  end

  def self.year_for(name)
    name.to_s[YEAR_IN_NAME, 1]&.to_i
  end

  def up
    add_column :slates, :sport, :string
    add_column :slates, :year, :integer
    add_index :slates, [:year, :week]

    say_with_time "backfilling slates.sport / slates.year from each name" do
      updated = 0
      Slate.reset_column_information
      Slate.find_each do |slate|
        slate.update_columns(sport: self.class.sport_for(slate.name), year: self.class.year_for(slate.name))
        updated += 1
      end
      updated
    end
  end

  def down
    remove_index :slates, [:year, :week]
    remove_column :slates, :year
    remove_column :slates, :sport
  end
end
