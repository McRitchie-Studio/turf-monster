require "test_helper"
require "yaml"
require "tmpdir"
require "json"
require "open3"

# Guard: turf-monster's on-chain E2E lane may not go quiet without going RED.
#
# WHAT HAPPENED, because the shape of it is the whole reason this file exists.
# The 18 @devnet specs in e2e/devnet-smoke.spec.js are the repo's only
# server-side on-chain coverage — ci.yml's playwright job excludes them on
# purpose to stay hermetic, so devnet-nightly.yml is the sole lane that runs
# them. That workflow gated its entire JOB on
# `if: vars.DEVNET_NIGHTLY_ENABLED == 'true'`. With the variable unset, every
# scheduled run completed **skipped**: green-adjacent grey, one second, twelve
# consecutive days of it (runs 31248719068 through 32233040903, 2026-08-08 to
# 2026-08-19), plus a hand dispatch on 2026-08-20 (32336618549) that did the
# same. Meanwhile config/feature_shapes.yml had dropped the e2e_onchain tier
# BECAUSE nothing ran it. Coverage did not break. It evaporated, and every
# mechanism that should have noticed was measuring the wrong thing.
#
# So the bug being guarded is NOT "the variable was unset." It is that being
# unset was SILENT. Restoring the variable fixes today; only a guard fixes the
# next time. Two halves, and the file asserts both:
#
#   1. SHAPE — devnet-nightly.yml carries no job-level `if:` that can skip the
#      whole lane, and its switches are checked in a step that EXITS NONZERO.
#   2. BITE — .github/scripts/devnet-lane-guard.sh, driven for real against
#      canned GitHub API bodies, actually fails on a lane that has never run,
#      one that has gone stale, and one reporting green over a suite that did
#      not execute.
#
# Half 1 alone would be the same mistake one level up: a guard asserting that a
# guard exists, never once checking that it fires. The bite tests below run the
# real script through a fake `gh` on PATH — no network, no token — because a
# detector nobody has watched detect anything is decoration.
class DevnetLaneGuardTest < ActiveSupport::TestCase
  ROOT = File.expand_path("../..", __dir__)
  NIGHTLY_YML = File.join(ROOT, ".github/workflows/devnet-nightly.yml")
  CI_YML = File.join(ROOT, ".github/workflows/ci.yml")
  GUARD_SH = File.join(ROOT, ".github/scripts/devnet-lane-guard.sh")

  # The step name devnet-nightly.yml gives the suite run. The script reads this
  # name back out of the API to prove a green run actually ran the specs, so a
  # rename on either side turns the check into a lookup over an empty set. The
  # value is asserted to appear in BOTH files below rather than trusted here.
  SUITE_STEP_NAME = "Run the @devnet Playwright suite".freeze

  def nightly = @nightly ||= YAML.safe_load_file(NIGHTLY_YML, aliases: true)
  def ci = @ci ||= YAML.safe_load_file(CI_YML, aliases: true)
  def nightly_job = nightly.fetch("jobs").fetch("devnet")
  def guard_job = ci.fetch("jobs").fetch("devnet_lane_guard")

  # ---------------------------------------------------------------------------
  # Half 1 — shape
  # ---------------------------------------------------------------------------

  test "the nightly job carries no condition that can skip the whole lane" do
    assert_nil nightly_job["if"],
               "the `devnet` job has a job-level `if:` again. That is the exact " \
               "construct that produced twelve days of `skipped` runs: when it is " \
               "false the run completes GREY, and nothing anywhere goes red. Gate " \
               "the lane in a step that exits nonzero instead."
  end

  test "every switch the lane needs is checked in a step that fails the run" do
    preflight = nightly_job.fetch("steps").find { |s| s["name"].to_s.start_with?("Preflight") }
    assert preflight, "devnet-nightly.yml has no preflight step; nothing names the lane's own switches."

    body = preflight.fetch("run")
    assert_match(/exit 1/, body,
                 "the preflight does not exit nonzero — it reports the lane is off and then passes anyway.")

    %w[DEVNET_NIGHTLY_ENABLED SOLANA_BOT_KEY SOLANA_RPC_URL].each do |switch|
      assert_includes preflight.fetch("env").keys, switch,
                      "the preflight cannot see #{switch}, so it cannot report it missing."
      assert_match(/#{switch}/, body, "the preflight never checks #{switch}.")
    end

    # It must be FIRST. A preflight behind `npm ci` still fails the run, but it
    # spends ten minutes of runner time to say a variable is unset.
    assert_equal preflight, nightly_job.fetch("steps").first,
                 "the preflight is not the first step; the lane pays for a full setup before reporting it is off."
  end

  test "the suite is selected positively, not by double negation" do
    step = nightly_job.fetch("steps").find { |s| s["name"] == SUITE_STEP_NAME }
    assert step, "no step named #{SUITE_STEP_NAME.inspect} in devnet-nightly.yml"

    assert_match(/--project=devnet/, step.fetch("run"),
                 "the suite must select the `devnet` project directly. Selecting by " \
                 "`--grep @devnet` alone reaches the same specs only because the " \
                 "`chromium` project sets `grepInvert: /@devnet/`; drop that while " \
                 "tuning the PR lane and every on-chain spec runs TWICE, at real cost.")
  end

  test "the script and the workflow agree on the suite step name" do
    assert_match(/^SUITE_STEP_NAME="#{Regexp.escape(SUITE_STEP_NAME)}"$/, File.read(GUARD_SH),
                 "devnet-lane-guard.sh looks for a step name the workflow no longer uses. " \
                 "The script would then find zero matching steps on every run.")
    assert File.executable?(GUARD_SH), "#{GUARD_SH} is not executable; the CI step would fail to exec it."
  end

  test "pull request CI runs the lane guard unconditionally and on the default window" do
    assert_nil guard_job["if"],
               "the lane guard has an `if:` — a guard that can skip itself is the bug it guards against."
    assert_equal 10, guard_job["timeout-minutes"]
    assert_equal "read", guard_job.dig("permissions", "actions"),
                 "the guard reads workflow-run history; without `actions: read` it fails on token scope, not on the lane."

    step = guard_job.fetch("steps").find { |s| s["run"].to_s.include?("devnet-lane-guard.sh") }
    assert step, "the devnet_lane_guard job does not run devnet-lane-guard.sh"
    refute_includes step.fetch("env").keys, "DEVNET_LANE_MAX_AGE_DAYS",
                    "ci.yml overrides the staleness window. The dial exists for hand-running " \
                    "the script; CI turning it up is how a guard gets quietly defused."
  end

  # ---------------------------------------------------------------------------
  # Half 2 — bite. The real script, a fake `gh`, no network.
  # ---------------------------------------------------------------------------

  def run_guard(runs:, jobs:, env: {})
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "runs.json"), JSON.dump(runs))
      File.write(File.join(dir, "jobs.json"), JSON.dump(jobs))
      # Fake gh: routes on the endpoint the script asks for. Anything else is a
      # hard error, so a script that grows a third call cannot silently read "".
      File.write(File.join(dir, "gh"), <<~SH)
        #!/usr/bin/env bash
        case "$*" in
          *"/runs?per_page="*) cat "#{dir}/runs.json" ;;
          *"/jobs"*)           cat "#{dir}/jobs.json" ;;
          *) echo "fake gh: unexpected call: $*" >&2; exit 64 ;;
        esac
      SH
      FileUtils.chmod(0o755, File.join(dir, "gh"))

      out, status = Open3.capture2e(
        { "PATH" => "#{dir}:#{ENV['PATH']}", "GH_REPO" => "McRitchie-Studio/turf-monster",
          "GITHUB_STEP_SUMMARY" => nil }.merge(env),
        GUARD_SH
      )
      [ status.exitstatus, out ]
    end
  end

  def run_body(conclusion: "success", age_days: 0, id: 42)
    created = (Time.now.utc - (age_days * 86_400)).iso8601
    { "workflow_runs" => [ { "id" => id, "conclusion" => conclusion, "created_at" => created,
                             "html_url" => "https://github.com/x/y/actions/runs/#{id}" } ] }
  end

  def jobs_body(step_name: SUITE_STEP_NAME, conclusion: "success")
    { "jobs" => [ { "steps" => [ { "name" => "Seed test DB", "conclusion" => "success" },
                                 { "name" => step_name, "conclusion" => conclusion } ] } ] }
  end

  test "a lane that has run recently and really ran the suite passes" do
    code, out = run_guard(runs: run_body(age_days: 1), jobs: jobs_body)
    assert_equal 0, code, "the guard failed a healthy lane:\n#{out}"
    assert_match(/lane is live/i, out)
  end

  # The 2026-08 disease itself: runs exist, every one of them skipped.
  test "a lane whose every run skipped is RED" do
    code, out = run_guard(runs: run_body(conclusion: "skipped"), jobs: jobs_body)
    assert_equal 1, code, "twelve days of `skipped` passed the guard:\n#{out}"
    assert_match(/never completed a run/i, out)
  end

  test "a lane with no runs at all is RED" do
    code, out = run_guard(runs: { "workflow_runs" => [] }, jobs: jobs_body)
    assert_equal 1, code
    assert_match(/never completed a run/i, out)
  end

  test "a lane whose newest success is older than the window is RED" do
    code, out = run_guard(runs: run_body(age_days: 4), jobs: jobs_body)
    assert_equal 1, code, "a four-day-old lane passed a three-day window:\n#{out}"
    assert_match(/gone quiet/i, out)
  end

  # The window is tolerance for a flaky devnet, not a loophole: inside it, pass.
  test "a single missed night stays green" do
    code, out = run_guard(runs: run_body(age_days: 2), jobs: jobs_body)
    assert_equal 0, code, "a two-day-old lane failed a three-day window:\n#{out}"
  end

  # A run-level `success` proves nothing about whether the specs ran. Both
  # spellings of that lie are checked, because this repo has been burned by the
  # green-over-nothing shape more than once.
  test "a green run that never executed the suite step is RED" do
    code, out = run_guard(runs: run_body, jobs: jobs_body(step_name: "Run the @devnet suite"))
    assert_equal 1, code, "a green run with no suite step passed:\n#{out}"
    assert_match(/without running the suite/i, out)
  end

  test "a green run whose suite step skipped is RED" do
    code, out = run_guard(runs: run_body, jobs: jobs_body(conclusion: "skipped"))
    assert_equal 1, code, "a green run whose suite step skipped passed:\n#{out}"
    assert_match(/did not succeed/i, out)
  end

  # Proves the window is a real variable and not a number the tests happen to
  # agree with — the same run is green at one setting and red at another.
  test "the staleness window is the thing being measured" do
    code, = run_guard(runs: run_body(age_days: 5), jobs: jobs_body,
                      env: { "DEVNET_LANE_MAX_AGE_DAYS" => "7" })
    assert_equal 0, code, "a 5-day-old lane failed a 7-day window"

    code, = run_guard(runs: run_body(age_days: 5), jobs: jobs_body,
                      env: { "DEVNET_LANE_MAX_AGE_DAYS" => "1" })
    assert_equal 1, code, "a 5-day-old lane passed a 1-day window"
  end
end
