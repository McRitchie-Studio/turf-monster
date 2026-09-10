# frozen_string_literal: true

require "test_helper"
require "rake"

# Drives the real `opsec:signing_key_isolation` rake task — the thing
# `bin/deploy` actually invokes — with only the SUBPROCESS faked. The Heroku CLI
# call is replaced by an injected runner; everything downstream of it (JSON
# parsing, presence detection, digesting, the verdict, the exit code, the
# printed report) is the production code path.
#
# This is where "the guard bites" is proved: the same task, handed two matching
# values, exits non-zero; handed two different ones, exits zero.
#
# It does NOT prove anything about the live apps. CI has no Heroku session and
# neither secret; the comparison against real config happens only in
# `bin/deploy`'s pre-flight on the operator's machine.
class OpsecSigningKeyIsolationTaskTest < ActiveSupport::TestCase
  # Obviously fake. A real credential never appears in a test or its output.
  SENTINEL_PROD = "SENTINEL-NOT-A-REAL-KEY-PRODUCTION-0000"
  SENTINEL_QA   = "SENTINEL-NOT-A-REAL-KEY-QA-1111"
  SENTINEL_BYSTANDER = "SENTINEL-NOT-A-REAL-KEY-RAILS-MASTER-2222"

  TASK = "opsec:signing_key_isolation"

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?(TASK)
    @task = Rake::Task[TASK]
    @task.reenable
  end

  test "the task FAILS when the two apps carry the same signing key" do
    status, output = run_task(mainnet: SENTINEL_PROD, qa: SENTINEL_PROD)

    refute_equal 0, status, "a shared signing key must fail the deploy guard"
    assert_match(/SHARED SIGNING KEY/, output)
    assert_match(/turf-monster-qa/, output)
    assert_no_sentinels output
  end

  test "the task PASSES when each app carries its own signing key" do
    status, output = run_task(mainnet: SENTINEL_PROD, qa: SENTINEL_QA)

    assert_equal 0, status, "distinct keys must let the deploy through"
    assert_match(/OK — turf-monster-qa signs with its own key/, output)
    assert_no_sentinels output
  end

  test "the task FAILS when a value is absent rather than reading it as distinct" do
    status, output = run_task(mainnet: SENTINEL_PROD, qa: :absent)

    refute_equal 0, status, "an absent QA key is not proof of isolation"
    assert_match(/INDETERMINATE/, output)
    assert_match(/key ABSENT/, output)
  end

  test "the task FAILS when a value is present but empty" do
    status, output = run_task(mainnet: SENTINEL_PROD, qa: "")

    refute_equal 0, status
    assert_match(/INDETERMINATE/, output)
    assert_match(/value EMPTY/, output)
  end

  test "the task FAILS when the heroku read itself fails" do
    # The unauthenticated / wrong-app / offline case. `heroku config:get` would
    # have returned a plausible blank line here and exited 0; `config --json`
    # fails the command, and the guard refuses rather than guessing.
    status, output = run_task(mainnet: SENTINEL_PROD, qa: :unreadable)

    refute_equal 0, status
    assert_match(/INDETERMINATE/, output)
    assert_match(/UNREADABLE/, output)
    assert_match(/heroku auth:whoami/, output, "the operator needs the next move")
  end

  test "the task FAILS when BOTH sides are unreadable" do
    status, output = run_task(mainnet: :unreadable, qa: :unreadable)

    refute_equal 0, status, "two failed reads must not compare as 'different'"
    assert_match(/INDETERMINATE/, output)
  end

  test "the task never prints a signing key, even while reporting a collision" do
    _status, output = run_task(mainnet: SENTINEL_PROD, qa: SENTINEL_PROD)

    assert_no_sentinels output
    # Floor: the refutations above are worthless against an empty transcript.
    assert_match(/Signing key isolation \(SOLANA_ADMIN_KEY\)/, output)
    assert_match(/sha256\[0,12\]=[0-9a-f]{12}/, output)
    assert_operator output.length, :>, 200, "the task printed almost nothing"
  end

  test "the task reads the mainnet and QA apps by name" do
    seen = []
    _status, output = run_task(mainnet: SENTINEL_PROD, qa: SENTINEL_QA, spy: seen)

    assert_equal %w[turf-monster-mainnet turf-monster-qa], seen.sort
    assert_match(/turf-monster-mainnet/, output)
    assert_match(/turf-monster-qa/, output)
  end

  private

  def assert_no_sentinels(output)
    [SENTINEL_PROD, SENTINEL_QA, SENTINEL_BYSTANDER].each do |sentinel|
      refute_includes output, sentinel, "the task published a credential"
    end
  end

  # Builds a fake `heroku config --json` payload per app and runs the task.
  #
  # @param mainnet [String, :absent, :unreadable] what turf-monster-mainnet answers
  # @param qa      [String, :absent, :unreadable] what turf-monster-qa answers
  # @return [Array(Integer, String)] exit status and captured stdout
  def run_task(mainnet:, qa:, spy: nil)
    answers = { "turf-monster-mainnet" => mainnet, "turf-monster-qa" => qa }

    runner = lambda do |app|
      spy << app if spy
      answer = answers.fetch(app)
      next ["", false] if answer == :unreadable

      # Every payload carries a bystander secret, so a reader that returned the
      # whole config blob instead of the one key would trip assert_no_sentinels.
      config = { "RAILS_MASTER_KEY" => SENTINEL_BYSTANDER }
      config["SOLANA_ADMIN_KEY"] = answer unless answer == :absent
      [config.to_json, true]
    end

    reader = TurfMonster::SigningKeyIsolation::HerokuReader.new(runner: runner)
    status = nil
    output, = capture_io do
      TurfMonster::SigningKeyIsolation::HerokuReader.stub(:new, reader) do
        # The task ends in `exit <code>`, so SystemExit is the normal finish.
        status = assert_raises(SystemExit) { @task.invoke }.status
      end
    end

    [status, output]
  end
end
