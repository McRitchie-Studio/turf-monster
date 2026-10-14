# frozen_string_literal: true

require "test_helper"

# bin/qa-contest-rehearsal's flags. Step 3 has three modes, and the defect this
# pins is the one that hid between them: `--pace` was read with to_i, so
# `--pace 0.4` became 0, and 0 meant poll-only — a "fast" run that never
# exercised the per-play chain it was meant to rehearse.
class QaRehearsalOptionsTest < ActiveSupport::TestCase
  Options = TurfMonster::QaRehearsal::Options

  test "a bare play is the unattended replay: every play, no pause" do
    step, options = Options.parse(%w[play])

    assert_equal "play", step
    assert_nil options[:pace], "no pace means no pause, not poll-only"
    assert options[:replay], "the default replays every play"
    assert options[:reset]
  end

  test "a fractional pace is kept, not truncated to zero" do
    _, options = Options.parse(%w[play --pace 0.4])

    assert_in_delta 0.4, options[:pace]
    assert options[:replay]
  end

  test "a whole pace still parses for a watched run" do
    _, options = Options.parse(%w[play --pace 4])

    assert_in_delta 4.0, options[:pace]
  end

  test "pace 0 is refused, because it used to mean poll-only" do
    error = assert_raises(Options::Invalid) { Options.parse(%w[play --pace 0]) }

    assert_match(/more than 0/, error.message)
    assert_match(/--no-replay/, error.message, "the refusal names the mode a zero used to mean")
  end

  test "a negative or unreadable pace is refused" do
    assert_raises(Options::Invalid) { Options.parse(%w[play --pace -1]) }
    assert_raises(Options::Invalid) { Options.parse(%w[play --pace fast]) }
    assert_raises(Options::Invalid) { Options.parse(%w[play --pace]) }
  end

  test "poll-only has to be asked for by name" do
    _, options = Options.parse(%w[play --no-replay])

    assert_equal false, options[:replay]
    assert_nil options[:pace]
  end

  test "a pace with --no-replay is refused: there is nothing to pace" do
    assert_raises(Options::Invalid) { Options.parse(%w[play --pace 2 --no-replay]) }
  end

  test "the other steps keep their flags" do
    step, options = Options.parse(%w[conclude --cosign link --cast mack])

    assert_equal "conclude", step
    assert_equal :link, options[:cosign]
    assert_equal %w[mack], options[:cast]

    _, options = Options.parse(%w[play --no-reset])
    assert_equal false, options[:reset]
  end

  test "no step answers nil, and the caller does not mutate" do
    argv = %w[--pace 1]
    step, = Options.parse(argv)

    assert_nil step
    assert_equal %w[--pace 1], argv
  end

  test "an unknown flag is refused with OptionParser's sentence" do
    error = assert_raises(Options::Invalid) { Options.parse(%w[play --speed 9]) }

    assert_match(/--speed/, error.message)
  end

  test "an ambiguous or needless flag is refused cleanly, not with a backtrace" do
    assert_raises(Options::Invalid) { Options.parse(%w[play --no-re]) }
    assert_raises(Options::Invalid) { Options.parse(%w[play --no-replay=x]) }
  end
end
