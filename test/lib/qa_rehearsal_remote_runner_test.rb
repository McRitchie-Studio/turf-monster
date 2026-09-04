# frozen_string_literal: true

require "test_helper"

# The runner's whole job is to pull ONE answer out of a very noisy transcript.
# These tests describe that noise honestly — heroku echoes the entire script
# back before running it — because the first version of this class tailed
# stderr and reported the tail of its own script as if it were the error.
class QaRehearsalRemoteRunnerTest < ActiveSupport::TestCase
  Runner = TurfMonster::QaRehearsal::RemoteRunner

  Status = Struct.new(:exitstatus) do
    def success? = exitstatus.zero?
  end

  def runner_returning(out:, err: "", exit_code: 0)
    executor = ->(_argv) { [out, err, Status.new(exit_code)] }
    Runner.new(app: "turf-monster-qa", executor: executor)
  end

  test "picks the marker line out of surrounding noise" do
    out = <<~OUT
      Running bin/rails runner on turf-monster-qa... up, run.1234
      DEPRECATION WARNING: something unrelated
      I, [2026-09-04] INFO -- : [solana] network alignment OK (devnet)
      #{Runner::MARKER} {"contest_slug":"qa-rehearsal-x","picks_required":6}
      some trailing chatter
    OUT

    result = runner_returning(out: out).call("emit(x: 1)")

    assert_equal "qa-rehearsal-x", result["contest_slug"]
    assert_equal 6, result["picks_required"]
  end

  # The marker must win over anything else JSON-shaped in the stream. A
  # transcript routinely contains JSON that is not the answer — a log line, an
  # inspected hash — and "the last thing that parses" would pick that up.
  test "ignores other JSON in the transcript" do
    out = <<~OUT
      {"level":"info","msg":"not the answer"}
      #{Runner::MARKER} {"answer":true}
      {"level":"info","msg":"also not the answer"}
    OUT

    assert_equal({ "answer" => true }, runner_returning(out: out).call("emit(answer: true)"))
  end

  test "a missing marker raises and reports what the remote actually said" do
    err = <<~ERR
      Running bin/rails runner "
      contest = Contest.create!(name: 'x')
      emit(ok: true)
      " on turf-monster-qa... up, run.9999
      /app/models/contest.rb:12:in `create!': Validation failed (ActiveRecord::RecordInvalid)
    ERR

    error = assert_raises(Runner::RemoteError) do
      runner_returning(out: "", err: err).call("emit(ok: true)")
    end

    # The exception, not the echo of our own script, is what an operator needs.
    assert_match(/Validation failed/, error.message)
    refute_match(/Contest.create!\(name/, error.message)
  end

  test "an unparseable answer is reported as such" do
    error = assert_raises(Runner::RemoteError) do
      runner_returning(out: "#{Runner::MARKER} {not json}").call("emit(x: 1)")
    end

    assert_match(/unparseable/, error.message)
  end

  # Learned the hard way: `$stdout.flush` in a remote script is expanded by the
  # DYNO's shell, arrives as `.flush`, and rails runner rejects the whole
  # thing — surfacing as "undefined method `flush\' for an instance of String",
  # which points nowhere near the cause.
  test "refuses source the dyno's shell would expand" do
    error = assert_raises(Runner::RemoteError) do
      runner_returning(out: "").call("puts 1\n$stdout.flush")
    end

    assert_match(/shell-expandable/, error.message)
    assert_match(/STDOUT/, error.message)
  end

  test "ordinary source with no shell variables passes the guard" do
    assert_equal({}, runner_returning(out: "#{Runner::MARKER} {}").call("STDOUT.flush; emit({})"))
  end

  test "the emit helper is prepended so callers never define it" do
    seen = nil
    executor = lambda do |argv|
      seen = argv.last
      ["#{Runner::MARKER} {}", "", Status.new(0)]
    end

    Runner.new(app: "turf-monster-qa", executor: executor).call("emit(ok: 1)")

    assert_match(/def emit\(payload\)/, seen)
    assert_match(/emit\(ok: 1\)/, seen)
  end
end
