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
    "app/models/slate.rb" =>
      "Slate#team_rankings — ranks teams per game and applies the line factor; the source of truth",
    "app/services/nfl/cache_expected_team_totals.rb" =>
      "the weekly ingest, writing team_rankings' answer and skipping picked rows",
    "app/services/nfl/build_span_slate.rb" =>
      "the span freeze, writing team_rankings' answer",
    "app/services/nfl/reprice_span_slate.rb" =>
      "the in-place reprice, writing team_rankings' answer under its refusals",
    "app/controllers/slates_controller.rb" =>
      "the admin drag + manual multiplier endpoints, which pass the team's game_factor",
    "app/services/world_cup2026_knockout_seed.rb" =>
      "World Cup seeding — one game per team, so no line factor exists",
    "app/services/nfl/build_preseason_slate.rb" =>
      "the preseason rehearsal slate — one game per team",
    "lib/tasks/slates.rake" =>
      "the recompute pass, which SKIPS any two-line slate rather than re-scaling stale ranks"
  }.freeze

  # `turf_score:` as a keyword in an assignment — update!, update_all, create!,
  # assign_attributes. Not a read, not a symbol in a pluck.
  ASSIGNMENT = /turf_score:\s*[^)\s]/

  test "only the sanctioned files write a price" do
    found = Dir.glob(Rails.root.join("{app,lib}/**/*.{rb,rake}")).select do |path|
      File.readlines(path).any? do |line|
        next false if line.strip.start_with?("#")

        ASSIGNMENT.match?(line)
      end
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
