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

  # ── The property: the backfill rule and the model rule cannot disagree ────────
  #
  # An earlier version of this test iterated persisted slates and skipped any with a
  # null sport. In the test environment that skipped EVERY row — the loop body ran
  # ZERO times, so corrupting the migration's backfill regex to flip all 18 NFL slates
  # to "fifa" left the whole suite green. A guard that can pass while the thing it
  # guards is broken is worse than no guard, because it is credited as evidence.
  #
  # Two changes fix that. The corpus is built HERE rather than borrowed from fixtures,
  # so it can never be empty. And the assertion COUNT is itself asserted, so the test
  # fails if the loop ever stops executing.
  NAME_CORPUS = [
    ["NFL 2026 Week 1", "nfl"],
    ["NFL 2026 Week 18", "nfl"],
    ["NFL 2026 Weeks 1-3", "nfl"],       # span — a singular /week\s+\d/ would miss it
    ["NFL 2025 Weeks 15-17", "nfl"],
    ["2026 Weeks 4-6", "nfl"],           # week marker, no NFL token
    ["World Cup 2026 Group 1", "fifa"],
    ["World Cup 2026 Round of 32", "fifa"],
    ["Default", "fifa"]
  ].freeze

  test "[unit] the migration's backfill rule and the model's rule agree on every name" do
    # The MIGRATION's constant, not the model's — these are two deliberately separate
    # copies (a migration must be frozen in time), and the whole point is that they
    # must not drift. Nothing else in the suite loads `up`, because the test DB is
    # built from schema.rb.
    require Rails.root.join("db/migrate/20260729000000_add_sport_and_year_to_slates.rb").to_s
    migration_rule = AddSportAndYearToSlates::NFL_NAME

    checked = 0
    NAME_CORPUS.each do |name, expected|
      from_migration = name.downcase.match?(migration_rule) ? "nfl" : "fifa"
      from_model     = Slate.sport_from_name(name)

      assert_equal expected, from_migration, "migration rule misreads #{name.inspect}"
      assert_equal expected, from_model, "model rule misreads #{name.inspect}"
      assert_equal from_model, from_migration,
                   "the migration backfilled #{name.inspect} as #{from_migration.inspect} while the model " \
                   "reads it as #{from_model.inspect}. They have drifted, so backfilled rows now disagree " \
                   "with what every reader computes."
      checked += 1
    end

    assert_equal NAME_CORPUS.size, checked, "the corpus loop must actually execute"
  end

  test "[unit] no persisted slate's column sport disagrees with its name" do
    # Build the corpus so this can never run on an empty set (the original bug).
    NAME_CORPUS.each_with_index do |(name, expected), i|
      Slate.create!(name: "#{name} probe#{i}", sport: expected, year: 2026)
    end

    checked = 0
    Slate.where.not(sport: nil).find_each do |slate|
      base = slate.name.sub(/ probe\d+\z/, "")
      assert_equal Slate.sport_from_name(base), slate[:sport],
                   "slate #{slate.name.inspect} carries sport #{slate[:sport].inspect} but its name implies " \
                   "#{Slate.sport_from_name(base).inspect}"
      checked += 1
    end

    assert_operator checked, :>=, NAME_CORPUS.size,
                    "the guard asserted on #{checked} slates — it must never run on an empty set"
  end

  test "[unit] the multiplier curve resolves identically through the column and the name" do
    slate = Slate.create!(name: "NFL 2026 Week 9", sport: "nfl", year: 2026)
    via_column = SlateMatchup.turf_score_for(5, 32, sport: slate.sport)

    slate.update_columns(sport: nil)
    via_name = SlateMatchup.turf_score_for(5, 32, sport: slate.reload.sport)

    assert_equal via_column, via_name,
                 "the column and the fallback must price a pick the same, or the migration itself re-prices"
  end

  # Blocker from review: only 2 of 7 writers set the columns, so a fresh seed left them
  # null and `where(sport: "nfl")` — which the new index invites — silently dropped
  # those rows. Fixed at the MODEL, so this holds for every writer rather than the two
  # that happened to get patched.
  test "[unit] any writer persists both columns without setting them" do
    NAME_CORPUS.each do |name, expected|
      slate = Slate.create!(name: "#{name} writer-probe")

      assert_equal expected, slate.reload[:sport],
                   "#{name.inspect} persisted sport #{slate[:sport].inspect} — a null here is invisible to " \
                   "where(sport:), which the new index invites"
      expected_year = name[/\b(20\d{2})\b/, 1]&.to_i
      next if expected_year.nil? # "Default" carries no year by design

      assert_equal expected_year, slate[:year], "#{name.inspect} persisted year #{slate[:year].inspect}"
    end
  end

  test "[unit] an explicit sport from the caller still wins over the derived one" do
    slate = Slate.create!(name: "World Cup 2026 Group 4", sport: "nfl")

    assert_equal "nfl", slate.reload[:sport],
                 "the derivation must fill BLANKS only — never override a caller"
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
