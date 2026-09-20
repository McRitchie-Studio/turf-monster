require "test_helper"
require "rake"

# The two rake doors onto a bye span's prices:
#   * slates:reprice_span — the operator's tool: dry run unless APPLY=1, and a
#     paid pick needs REPRICE_PAID_PICKS naming the SAME slate.
#   * slates:recompute_turf_scores — must SKIP a two-line slate, because
#     re-scaling ranks frozen under the summed-total rule overprices bye teams.
class SlatesRepriceSpanTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("slates:reprice_span")
    @slate = Slate.create!(name: "NFL 2026 Weeks 4-6", slug: "nfl-2026-weeks-4-6")
    add_games!("full-a", 3, 26.0, rank: 1, turf: 1.0)
    add_games!("bye-b", 2, 27.0, rank: 2, turf: 2.0)
  end

  teardown do
    %w[APPLY REPRICE_PAID_PICKS].each { |key| ENV.delete(key) }
  end

  def add_games!(team_slug, count, score, rank:, turf:)
    Team.find_or_create_by!(slug: team_slug) { |team| team.name = team_slug.titleize }
    count.times do |index|
      opponent = "opp-#{team_slug}-#{index}"
      Team.find_or_create_by!(slug: opponent) { |team| team.name = opponent.titleize }
      game = Game.create!(slug: "#{team_slug}-vs-#{opponent}", home_team_slug: team_slug,
                          away_team_slug: opponent, status: "scheduled", kickoff_at: 10.days.from_now)
      SlateMatchup.create!(slate: @slate, team_slug: team_slug, opponent_team_slug: opponent,
                           game_slug: game.slug, expected_score: score, status: "pending",
                           rank: rank, turf_score: turf)
    end
  end

  def run_task(name, *args)
    task = Rake::Task[name]
    task.reenable
    capture_io { task.invoke(*args) }.first
  end

  def bye_price
    @slate.slate_matchups.where(team_slug: "bye-b").pick(:turf_score).to_f
  end

  test "reprice_span is a dry run by default" do
    out = run_task("slates:reprice_span", @slate.slug)

    assert_match(/DRY RUN/, out)
    assert_match(/bye-b .* 1\.5x/, out)
    assert_equal 2.0, bye_price
  end

  test "reprice_span writes with APPLY=1" do
    ENV["APPLY"] = "1"

    out = run_task("slates:reprice_span", @slate.slug)

    assert_match(/APPLIED/, out)
    assert_equal 1.5, bye_price
  end

  test "a paid pick needs REPRICE_PAID_PICKS naming this very slate" do
    Selection.create!(entry: Entry.create!(user: users(:alex), contest: contests(:one), status: :active),
                      slate_matchup: @slate.slate_matchups.find_by(team_slug: "bye-b"))
    ENV["APPLY"] = "1"
    ENV["REPRICE_PAID_PICKS"] = "some-other-slate"

    error = assert_raises(SystemExit) { run_task("slates:reprice_span", @slate.slug) }
    assert_not error.success?
    assert_equal 2.0, bye_price, "an override naming another slate must not unlock this one"

    ENV["REPRICE_PAID_PICKS"] = @slate.slug
    run_task("slates:reprice_span", @slate.slug)
    assert_equal 1.5, bye_price
  end

  test "recompute_turf_scores skips a two-line slate and names the tool to use" do
    out = run_task("slates:recompute_turf_scores")

    assert_match(/#{@slate.slug}: SKIPPED .*slates:reprice_span/, out)
    assert_equal 2.0, bye_price, "stored ranks from the old rule must not be re-scaled"
  end
end
