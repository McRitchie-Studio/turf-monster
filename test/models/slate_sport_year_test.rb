# frozen_string_literal: true

require "test_helper"

# [unit] `slates.sport` / `slates.year` as COLUMNS, with the old name-parsing kept as a
# fallback for rows written before this migration.
#
# The load-bearing property is VALUE PRESERVATION, not "the column exists". `sport`
# selects the multiplier curve (`SlateMatchup.turf_score_for(rank, n, sport:)`) and the
# frozen `turf_score` it produces is what `Selection#compute_points!` settles on-chain.
# A slate whose sport FLIPS re-prices every pick already made on it. So the tests that
# matter assert the column agrees with what the name always implied — for every slate,
# including the ones the fixtures happen to define.
class SlateSportYearTest < ActiveSupport::TestCase
  test "[unit] sport reads the column when set" do
    slate = Slate.create!(name: "Anything At All", sport: "nfl", year: 2026)

    assert_equal "nfl", slate.sport, "the column wins over anything the name implies"
  end

  test "[unit] sport falls back to the name when the column is null" do
    slate = Slate.create!(name: "NFL 2026 Week 4")
    slate.update_columns(sport: nil)

    assert_equal "nfl", slate.reload.sport,
                 "a null column must degrade to the pre-migration rule, never to a wrong answer"
  end

  test "[unit] the name fallback still treats a span slate as football" do
    # `weeks?` — a span is named "Weeks 1-3", which a singular `week\s+\d` would miss.
    assert_equal "nfl", Slate.sport_from_name("NFL 2026 Weeks 1-3")
    assert_equal "nfl", Slate.sport_from_name("2026 Weeks 1-3")
    assert_equal "fifa", Slate.sport_from_name("World Cup 2026 Group 1")
  end

  test "[unit] season_year reads the column and returns a String" do
    slate = Slate.create!(name: "NFL 2026 Week 4", year: 2026)

    # String, because every caller compares it against another #season_year and the
    # name-derived form was always a String. An Integer here would make a column-backed
    # slate silently stop matching a fallback one.
    assert_equal "2026", slate.season_year
  end

  test "[unit] season_year falls back to the name when the column is null" do
    slate = Slate.create!(name: "NFL 2026 Week 4")
    slate.update_columns(year: nil)

    assert_equal "2026", slate.reload.season_year
  end

  # ── The property that protects settlement ─────────────────────────────────────
  test "[unit] no persisted slate's column sport disagrees with its name" do
    slates = Slate.where.not(name: "Default").to_a
    refute_empty slates, "no slates loaded — this guard would be vacuous"

    slates.each do |slate|
      next if slate[:sport].blank? # a null legitimately falls back; nothing to disagree with

      assert_equal Slate.sport_from_name(slate.name), slate[:sport],
                   "slate #{slate.name.inspect} carries sport #{slate[:sport].inspect} but its name implies " \
                   "#{Slate.sport_from_name(slate.name).inspect}. A sport flip re-prices every pick on this " \
                   "slate — turf_score_for keys the multiplier curve on it."
    end
  end

  test "[unit] the multiplier curve resolves identically through the column and the name" do
    slate = Slate.create!(name: "NFL 2026 Week 9", sport: "nfl", year: 2026)
    via_column = SlateMatchup.turf_score_for(5, 32, sport: slate.sport)

    slate.update_columns(sport: nil)
    via_name = SlateMatchup.turf_score_for(5, 32, sport: slate.reload.sport)

    assert_equal via_column, via_name,
                 "the column and the fallback must price a pick the same, or the migration itself re-prices"
  end

  test "[unit] a slate built through the real NFL path carries both columns" do
    slate = Slate.create!(name: "NFL 2026 Week 12")
    slate.update_columns(sport: nil, year: nil)

    # ensure_slate! backfills on every save, not only on create.
    rebuilt = Slate.find_or_initialize_by(name: "NFL 2026 Week 12")
    rebuilt.week = 12
    rebuilt.sport = "nfl"
    rebuilt.year = 2026
    rebuilt.save!

    assert_equal "nfl", rebuilt.reload[:sport]
    assert_equal 2026, rebuilt[:year]
  end
end
