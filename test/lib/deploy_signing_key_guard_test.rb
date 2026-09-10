# frozen_string_literal: true

require "test_helper"
require "rake"

# `bin/deploy` is turf-monster's production deploy strategy — the script
# `bin/release ship` dispatches for this repo. The signing-key isolation guard
# is only worth anything if that script actually runs it, runs it FATALLY, and
# runs it on the path an operator really takes.
#
# This test reads a shell script, which makes it exit-blind by nature: a
# truncated, moved, or emptied `bin/deploy` would satisfy every "does not
# contain" assertion by containing nothing at all. So it asserts a FLOOR first —
# the script's size and the sibling pre-flight checks that were there before
# this task — and only then asserts the new wiring. Delete the pre-flight and
# this goes red rather than quietly passing.
class DeploySigningKeyGuardTest < ActiveSupport::TestCase
  TASK_NAME = "opsec:signing_key_isolation"

  # Pre-flight checks that predate this guard. Their presence is the evidence
  # that we are reading a whole `bin/deploy`, not a stub.
  SIBLING_CHECKS = [
    "Pre-flight checks",
    "EXPECTED_IDL_HASH",
    "SKIP_IDL_VERIFICATION",
    "STRIPE_SECRET_KEY",
    "Working tree clean"
  ].freeze

  setup do
    @path = Rails.root.join("bin/deploy")
    @script = @path.read
  end

  test "bin/deploy is present and substantial — the floor for every check below" do
    assert @path.exist?, "bin/deploy is missing; the deploy guard has nowhere to live"
    assert_operator @script.bytesize, :>, 6_000,
                    "bin/deploy is far smaller than expected — this test would pass vacuously"
    assert_operator @script.lines.count, :>, 150, "bin/deploy is unexpectedly short"

    SIBLING_CHECKS.each do |marker|
      assert_includes @script, marker,
                      "bin/deploy lost its #{marker.inspect} pre-flight — the file under test is not the deploy script"
    end
  end

  test "bin/deploy invokes the signing-key isolation task" do
    assert_includes @script, "bin/rails #{TASK_NAME}",
                    "bin/deploy no longer runs the signing-key isolation guard"
  end

  test "the task bin/deploy names actually exists" do
    # bin/deploy couples to the rake task by STRING. A rename on either side
    # would otherwise surface only at deploy time, on the money path.
    Rails.application.load_tasks unless Rake::Task.task_defined?(TASK_NAME)

    assert Rake::Task.task_defined?(TASK_NAME),
           "bin/deploy calls #{TASK_NAME}, but no such rake task is defined"
  end

  test "a failed isolation check aborts the deploy instead of warning" do
    region = script_region_after(TASK_NAME, lines: 8)

    assert_includes region, "fail ",
                    "the isolation check does not abort the deploy — a guard that only warns is worse than none"
    refute_includes region, "warn ",
                    "the isolation check downgrades to a warning"
  end

  test "the isolation check runs inside the pre-flight, not after the push" do
    guard_at = @script.index("bin/rails #{TASK_NAME}")
    preflight_at = @script.index('if [ "$SKIP_CHECKS" != "1" ]; then')
    deploy_at = @script.index("# ── Confirmation")

    refute_nil guard_at
    refute_nil preflight_at
    refute_nil deploy_at
    assert_operator guard_at, :>, preflight_at, "the guard runs before the pre-flight block opens"
    assert_operator guard_at, :<, deploy_at, "the guard runs after the deploy is already confirmed"
  end

  test "SKIP_TESTS does not skip the isolation check" do
    # SKIP_TESTS=1 is a routine operator shortcut. It must drop the test suite
    # and nothing else; the isolation guard has to sit above that branch.
    guard_at = @script.index("bin/rails #{TASK_NAME}")
    skip_tests_at = @script.index('if [ "${SKIP_TESTS:-0}" != "1" ]; then')

    refute_nil skip_tests_at, "bin/deploy's SKIP_TESTS branch moved — re-check where the guard sits"
    assert_operator guard_at, :<, skip_tests_at,
                    "the isolation guard sits inside the SKIP_TESTS branch and can be skipped with it"
  end

  test "bin/deploy does not read the signing key with heroku config:get" do
    # `config:get` cannot tell an absent key from an empty one from a failed
    # read — docs/SOLANA.md, "Check it by KEY PRESENCE". The guard uses
    # `heroku config --json`.
    refute_match(/config:get\s+SOLANA_ADMIN_KEY/, @script,
                 "bin/deploy reads the signing key with the ambiguous config:get form")
  end

  private

  # The N lines following the first line that mentions `needle`.
  def script_region_after(needle, lines:)
    all = @script.lines
    index = all.index { |line| line.include?(needle) }
    refute_nil index, "#{needle} not found in bin/deploy"
    all[index, lines + 1].join
  end
end
