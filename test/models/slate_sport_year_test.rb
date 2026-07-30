# frozen_string_literal: true

require "test_helper"

# [unit] `slates.sport` / `slates.year` as COLUMNS, with the old name-parsing kept as a
# fallback for rows written before this migration.
#
# The load-bearing property is VALUE PRESERVATION, not "the column exists". `sport`
# selects the multiplier curve (`SlateMatchup.turf_score_for(rank, n, sport:)`).
# Settlement reads the PERSISTED `slate_matchups.turf_score` and never recomputes, so a
# flipped sport cannot re-price a pick already made — it corrupts the NEXT ranking. That
# is still worth guarding, so the tests that matter assert the migration's rule and the
# model's rule cannot drift, over a corpus built here rather than borrowed.
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

    checked = 0
    NAME_CORPUS.each do |name, expected|
      # CALL the migration's own derivation — do not re-implement it here. An earlier
      # version compared only the CONSTANT, so inverting the ternary inside `up` (which
      # backfills all 28 slates wrong) left this green.
      from_migration = AddSportAndYearToSlates.sport_for(name)
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

  # The migration writes TWO columns and only `sport` had a drift test. A `year` rule
  # that misreads is just as damaging: `/(19\d{2})/` backfills every year NULL, and
  # `/(\d{1,2})/` makes "Week 3" a year-3 slate.
  test "[unit] the migration's year rule executes and agrees with the model" do
    require Rails.root.join("db/migrate/20260729000000_add_sport_and_year_to_slates.rb").to_s

    checked = 0
    NAME_CORPUS.each do |name, _sport|
      expected = name[/\b(20\d{2})\b/, 1]&.to_i
      from_migration = AddSportAndYearToSlates.year_for(name)
      from_model     = Slate.year_from_name(name)

      if expected.nil?
        assert_nil from_migration, "migration year rule invented a year for #{name.inspect}"
        assert_nil from_model, "model year rule invented a year for #{name.inspect}"
      else
        assert_equal expected, from_migration, "migration year rule misreads #{name.inspect}"
        assert_equal expected, from_model, "model year rule misreads #{name.inspect}"
      end
      assert_equal from_model, from_migration, "the year rules have drifted on #{name.inspect}"
      checked += 1
    end

    assert_equal NAME_CORPUS.size, checked, "the corpus loop must actually execute"
    # A bounded rule, asserted directly: an unbounded \d{1,2} would read "Week 3" as a year.
    assert_nil AddSportAndYearToSlates.year_for("NFL Week 3"), "a week number must never read as a year"
  end

  # Deliberately does NOT pass sport/year in — seeding a row with the answer and then
  # asserting the answer is a tautology. These rows are created the way a real writer
  # creates them, so the derivation is what fills them.
  test "[unit] no persisted slate's column sport disagrees with its name" do
    NAME_CORPUS.each_with_index { |(name, _expected), i| Slate.create!(name: "#{name} probe#{i}") }

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
                 "the column and the fallback must select the same curve, or the migration changes future pricing"
  end

  # Blocker from review: only 2 of 7 writers set the columns, so a fresh seed left them
  # null and the live `where(sport: "nfl")` in BuildSpanSlate silently dropped those rows.
  # Fixed at the MODEL, so this holds for every writer rather than the two that happened
  # to get patched. (There is no `sport` index — the migration refuses one; the hazard is
  # the query, not an index.)
  test "[unit] any writer persists both columns without setting them" do
    NAME_CORPUS.each do |name, expected|
      slate = Slate.create!(name: "#{name} writer-probe")

      assert_equal expected, slate.reload[:sport],
                   "#{name.inspect} persisted sport #{slate[:sport].inspect} — a null here is invisible to " \
                   "the live where(sport:) scope in BuildSpanSlate"
      expected_year = name[/\b(20\d{2})\b/, 1]&.to_i
      next if expected_year.nil? # "Default" carries no year by design

      assert_equal expected_year, slate[:year], "#{name.inspect} persisted year #{slate[:year].inspect}"
    end
  end

  # There are TWO different absences and they behave differently. A reviewer measured
  # both, which corrected this test's original premise — it had claimed a partial select
  # "reproduces" the post-rollback state and that `self.sport =` raises there. Neither
  # is true:
  #
  #                         post-rollback (column GONE)   partial select (NOT loaded)
  #   self[:sport]          nil                            RAISES MissingAttributeError
  #   self.sport =          RAISES NoMethodError            works (the setter exists)
  #
  # So the partial select exercises the READER guards, and only a genuinely rolled-back
  # schema exercises the WRITER guard. Both are covered below rather than conflated.
  test "[unit] readers survive a partial select, where the attribute is not loaded" do
    Slate.create!(name: "NFL 2026 Week 21")
    partial = Slate.select(:id, :name, :slug).find_by(name: "NFL 2026 Week 21")

    refute partial.has_attribute?(:sport), "precondition: the attribute must not be loaded"
    # Without the has_attribute? guards these raise MissingAttributeError.
    assert_equal "nfl", partial.sport, "#sport must fall back rather than raise"
    assert_equal "2026", partial.season_year, "#season_year must fall back rather than raise"
  end

  test "[unit] the writer guard checks has_attribute? before assigning" do
    slate = Slate.new(name: "NFL 2026 Week 22")

    # The guard is what makes the post-rollback write survivable: with the column gone,
    # `self.sport =` raises NoMethodError. Assert the guard is CONSULTED, so removing it
    # cannot pass silently — a rolled-back schema cannot be built inside this suite,
    # which is why the previous version of this test was asserting nothing.
    called = []
    slate.define_singleton_method(:has_attribute?) do |attr|
      called << attr.to_sym
      super(attr)
    end
    slate.valid?

    assert_includes called, :sport, "derivation must consult has_attribute?(:sport) before writing"
    assert_includes called, :year, "derivation must consult has_attribute?(:year) before writing"
  end

  # Pins the MECHANISM, not just the outcome. Reverting `source_slates` to
  # `where("name LIKE ?", "NFL <year> %")` passes every other test in this suite, because
  # a conventionally-named slate satisfies both. Only a slate whose COLUMNS are right
  # while its NAME would defeat the LIKE can tell them apart — which is also the real
  # scenario the columns exist for: a renamed slate must still be findable.
  test "[integration] BuildSpanSlate finds a source by COLUMN, not by its name" do
    team_a = Team.create!(slug: "ccc-test", name: "CCC", league: "nfl")
    team_b = Team.create!(slug: "ddd-test", name: "DDD", league: "nfl")
    # Name deliberately does NOT start with "NFL 2032" — a name-LIKE scope misses it.
    weekly = Slate.create!(name: "Week 1 Showcase 2032", week: 1, sport: "nfl", year: 2032)
    refute weekly.name.start_with?("NFL 2032"), "precondition: the name must defeat a LIKE scope"

    game = Game.create!(slug: "ccc-test-vs-ddd-test", home_team_slug: team_a.slug,
                        away_team_slug: team_b.slug, status: "scheduled")
    SlateMatchup.create!(slate: weekly, team_slug: team_a.slug, opponent_team_slug: team_b.slug,
                         game_slug: game.slug, week: 1, dk_goals_expectation: 21.0)

    span = Nfl::BuildSpanSlate.call(year: 2032, weeks: [1])

    assert_equal 1, span.slate_matchups.count,
                 "the span must be assembled from the column-matched source; a name-LIKE scope " \
                 "would have raised 'no slate for week 1'"
  end

  # The span entry point (contests_controller.rb:1705) used to read the year from the name
  # with an UNBOUNDED /\b(\d{4})\b/, so a slate named "Week 1234 Showcase" resolved year
  # 1234. It now reads #season_year, which is column-first and bounded to 20xx. Asserted
  # here rather than in a controller test because the property belongs to the reader.
  test "[unit] season_year is bounded, so a 4-digit non-year cannot read as a year" do
    slate = Slate.create!(name: "Week 1234 Showcase", week: 1)

    assert_nil slate.season_year,
               "an unbounded /\\b(\\d{4})\\b/ would return \"1234\" here and build a year-1234 span"
    assert_equal "1234", slate.name[/\b(\d{4})\b/, 1],
                 "sanity: the old unbounded rule really did match this name"
  end

  test "[unit] an explicit sport from the caller still wins over the derived one" do
    slate = Slate.create!(name: "World Cup 2026 Group 4", sport: "nfl")

    assert_equal "nfl", slate.reload[:sport],
                 "the derivation must fill BLANKS only — never override a caller"
  end

  # Named for the real path, so it must CALL the real path. The previous version
  # hand-rolled a find_or_initialize_by that mimicked `ensure_slate!` without invoking
  # it, leaving both service hunks with zero coverage.
  test "[integration] Nfl::BuildSpanSlate's slate carries both columns" do
    team_a = Team.create!(slug: "aaa-test", name: "AAA", league: "nfl")
    team_b = Team.create!(slug: "bbb-test", name: "BBB", league: "nfl")
    weekly = Slate.create!(name: "NFL 2031 Week 1", week: 1)
    game = Game.create!(slug: "aaa-test-vs-bbb-test",
                        home_team_slug: team_a.slug, away_team_slug: team_b.slug, status: "scheduled")
    SlateMatchup.create!(slate: weekly, team_slug: team_a.slug, opponent_team_slug: team_b.slug,
                         game_slug: game.slug, week: 1, dk_goals_expectation: 20.0)

    span = Nfl::BuildSpanSlate.call(year: 2031, weeks: [1])

    assert_equal "nfl", span.reload[:sport], "the span slate must persist its sport column"
    assert_equal 2031, span[:year], "the span slate must persist its year column"
  end
end
