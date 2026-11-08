# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require_relative "../../bin/lib/e2e_repeat_changed"

# The determinism check at the door (task deterministic-ci): a PR's changed Playwright
# specs run in five fresh passes in its own playwright lane.
class E2eRepeatChangedTest < Minitest::Test
  WORKFLOW = File.expand_path("../../.github/workflows/ci.yml", __dir__)

  def test_picks_added_changed_and_renamed_specs_and_drops_deleted_ones
    diff = "M\te2e/a.spec.js\nA\te2e/nested/b.spec.js\nR087\te2e/old.spec.js\te2e/new.spec.js\n" \
           "D\te2e/gone.spec.js\nM\te2e/helpers.js\nM\tapp/models/task.rb\n"
    assert_equal %w[e2e/a.spec.js e2e/nested/b.spec.js e2e/new.spec.js], E2eRepeatChanged.changed_specs(diff)
  end

  def test_no_spec_changed_runs_nothing
    assert_empty E2eRepeatChanged.changed_specs("M\te2e/helpers.js\n")
    assert_nil E2eRepeatChanged.command([])
  end

  def test_each_pass_is_one_fresh_run_without_a_receipt
    cmd = E2eRepeatChanged.command(["e2e/a.spec.js"])
    assert_equal %w[npx playwright test e2e/a.spec.js --grep-invert @devnet --reporter=list --pass-with-no-tests], cmd
    refute(cmd.any? { |a| a.include?("json") }, "a json reporter would write a second executed-set receipt")
    refute_includes cmd, "--repeat-each", "repeats inside one boot meet the seed already consumed"
  end

  # A changed spec that is all @devnet (e2e/devnet-smoke.spec.js) filters to no tests;
  # without the flag Playwright exits 1 on "No tests found" and every shard goes red.
  def test_a_changed_spec_that_is_all_devnet_is_not_a_red
    assert_includes E2eRepeatChanged.command(["e2e/devnet-smoke.spec.js"]), "--pass-with-no-tests"
  end

  def test_five_passes_dealt_round_robin_over_the_shards
    assert_equal [1, 2, 3, 4, 5], E2eRepeatChanged.passes
    assert_equal [[1, 4], [2, 5], [3]], %w[1/3 2/3 3/3].map { |s| E2eRepeatChanged.passes(s) }
    assert_equal [1, 2, 3, 4, 5], %w[1/3 2/3 3/3].flat_map { |s| E2eRepeatChanged.passes(s) }.sort
  end

  def test_reads_the_pr_diff_from_the_merge_commits_first_parent
    calls = []
    run = ->(argv) { calls << argv; ["M\te2e/a.spec.js\n", true] }
    out = E2eRepeatChanged.name_status(env: { "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_SHA" => "abc" }, run: run)
    assert_equal "M\te2e/a.spec.js\n", out
    assert_equal ["git", "diff", "--name-status", "-M", "abc^1", "abc"], calls.last
  end

  def test_a_push_repeats_nothing
    assert_nil E2eRepeatChanged.name_status(env: { "GITHUB_EVENT_NAME" => "push" }, run: ->(_) { flunk "no git on a push" })
  end

  def test_the_playwright_lane_runs_it_after_the_suite_on_every_shard
    steps = YAML.safe_load(File.read(WORKFLOW)).dig("jobs", "playwright", "steps")
    names = steps.map { |s| s["name"] }
    suite = names.index("Run Playwright (excluding @devnet)")
    repeat = names.index("Repeat this PR's changed specs five times")
    assert repeat && suite && repeat > suite, "the repeat step must follow the whole-suite step"
    step = steps[repeat]
    assert_equal "bin/e2e-repeat-changed --shard=${{ matrix.shard }}/${{ strategy.job-total }}", step["run"]
    assert_nil step["if"], "the check runs on every PR; it decides itself when there is nothing to repeat"
  end
end
