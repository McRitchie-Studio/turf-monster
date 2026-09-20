require "test_helper"

# [unit] WHO IS ALLOWED TO WRITE A PRICE.
#
# `turf_score` is the column settlement multiplies by. Every correct writer
# ranks the TEAM first and prices that rank on the team's own line; a writer
# that prices a ROW instead gets both the denominator and the bye factor wrong,
# silently, and looks perfectly reasonable while doing it. That is not
# hypothetical — `SlateMatchup#compute_turf_score!` was exactly that shape and
# survived only because nothing ever called it.
#
# A comment cannot stop the next one; this scan can. It is deliberately a SOURCE
# scan rather than a behavioural test: the failure mode is a NEW writer
# appearing, which no existing test would exercise.
class TurfScoreWritersTest < ActiveSupport::TestCase
  # Every file under app/ or lib/ permitted to assign turf_score, and why.
  SANCTIONED = {
    "app/services/nfl/cache_expected_team_totals.rb" =>
      "the weekly ingest, writing team_rankings' answer and skipping picked rows",
    "app/services/nfl/build_span_slate.rb" =>
      "the span freeze, writing team_rankings' answer",
    "app/services/nfl/reprice_span_slate.rb" =>
      "the in-place reprice, writing team_rankings' answer under its refusals",
    "app/controllers/slates_controller.rb" =>
      "the admin drag + manual multiplier endpoints, which pass the team's game_factor",
    "app/services/world_cup2026_knockout_seed.rb" =>
      "World Cup seeding — one fixture per team, so rows ARE teams and no line factor exists",
    "app/services/nfl/build_preseason_slate.rb" =>
      "the preseason rehearsal slate — one game per team, so rows ARE teams",
    "lib/tasks/slates.rake" =>
      "the recompute pass, which SKIPS any two-line slate rather than re-scaling stale ranks"
  }.freeze

  # A PERSISTENCE call carrying turf_score — the only thing that can change what
  # a player is paid.
  #
  # Two wrong versions preceded this one, and both failure modes are worth
  # naming. A bare `turf_score:` keyword flagged `Slate#team_rankings` and
  # `BenchmarksHelper`, which build hashes and Data objects for the page: a
  # guard that cries wolf on rendering code gets suppressed, and then it guards
  # nothing. Keying on the verb but scanning LINE by line then missed
  # `Nfl::BuildPreseasonSlate`, whose `update!` wraps across three lines —
  # under-flagging, which is worse, because it reads as a pass.
  #
  # So: strip comments, join continuation lines into whole statements, then ask
  # who WRITES. `new` is deliberately absent — a constructor persists nothing,
  # and including it is exactly what flagged the chart helper.
  WRITERS = /(?:update!?|update_all|update_columns|update_attribute|create!?|
               assign_attributes|insert_all!?|upsert_all)\b[^\n]*turf_score:/x

  # Whole statements, not source lines: a call broken across lines is one write.
  def statements_in(path)
    source = File.readlines(path).reject { |line| line.strip.start_with?("#") }.join
    source.gsub(/\(\s*\n\s*/, "(").gsub(/,\s*\n\s*/, ", ").lines
  end

  test "only the sanctioned files write a price" do
    found = Dir.glob(Rails.root.join("{app,lib}/**/*.{rb,rake}")).select do |path|
      statements_in(path).any? { |statement| WRITERS.match?(statement) }
    end.map { |path| Pathname(path).relative_path_from(Rails.root).to_s }.sort

    unexpected = found - SANCTIONED.keys
    assert_empty unexpected,
                 "a NEW writer of turf_score appeared: #{unexpected.join(', ')}. " \
                 "Price the TEAM, not the row — rank on points per game and pass the team's " \
                 "game_factor (Slate 'Two lines') — then add the file here with its reason."

    # The list cannot rot in the other direction either: a sanctioned file that
    # stops writing prices should leave this list rather than sit here implying
    # a route that no longer exists.
    assert_empty SANCTIONED.keys - found,
                 "these files no longer write turf_score; drop them from SANCTIONED"
  end

  # The specific shape that was deleted: a per-ROW price with no line factor.
  test "no price is written from a matchup's own row count" do
    offenders = Dir.glob(Rails.root.join("app/models/*.rb")).select do |path|
      source = File.read(path)
      source.match?(/def compute_turf_score!/) ||
        source.match?(/turf_score:.*turf_score_for\([^)]*slate_matchups\.count/)
    end

    assert_empty offenders,
                 "a row-counted price is wrong twice: n must be the TEAM count (32), not the " \
                 "row count (96 on a span), and a bye team needs its game_factor"
  end
end
