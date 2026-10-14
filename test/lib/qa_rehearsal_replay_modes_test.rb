# frozen_string_literal: true

require "test_helper"

# Step 3's modes, at the driver: the pace is for eyes only, so dropping it must
# change nothing but the pause, and a zero must not slip through to poll-only.
class QaRehearsalReplayModesTest < ActiveSupport::TestCase
  Driver = TurfMonster::QaRehearsal::Driver

  def stubbed_driver(already_scored: true)
    driver = Driver.new(io: StringIO.new)
    manifest = Struct.new(:data) do
      def read = data
      def merge(*) = data
    end.new({ "contest_slug" => "qa-rehearsal-x", "kickoff_shift_seconds" => 0 })
    calls = []
    driver.define_singleton_method(:guard!) { calls << :guard; {} }
    driver.define_singleton_method(:manifest) { manifest }
    driver.define_singleton_method(:slate_already_scored?) { already_scored }
    driver.define_singleton_method(:unshift_fixture) { |_s| nil }
    driver.define_singleton_method(:lock_contest) { |_slug| nil }
    driver.define_singleton_method(:replay) { |pace| calls << [:replay, pace]; :replayed }
    driver.define_singleton_method(:remote) { Struct.new(:x).new(nil).tap { |r| r.define_singleton_method(:call) { |_s| {} } } }
    driver.define_singleton_method(:system) { |*_args| calls << :poll; true }
    [driver, calls]
  end

  test "the unattended default replays every play with no pace" do
    driver, calls = stubbed_driver

    assert_equal :replayed, driver.play_preseason
    assert_includes calls, [:replay, nil]
  end

  test "a watched pace reaches the replay as given" do
    driver, calls = stubbed_driver

    driver.play_preseason(pace: 0.5)

    assert_includes calls, [:replay, 0.5]
  end

  test "pace 0 is refused before anything runs" do
    driver, calls = stubbed_driver

    error = assert_raises(Driver::StepError) { driver.play_preseason(pace: 0) }

    assert_match(/more than 0 seconds/, error.message)
    assert_empty calls, "nothing — not even the guard — runs on a refused pace"
  end

  test "poll-only is the one mode that re-lays nothing" do
    driver, calls = stubbed_driver(already_scored: false)

    driver.play_preseason(replay: false)

    assert_includes calls, :poll
    refute(calls.any? { |c| c.is_a?(Array) && c.first == :replay })
  end

  test "an unattended run on a fresh slate polls first, then replays" do
    driver, calls = stubbed_driver(already_scored: false)

    driver.play_preseason

    assert_equal %i[poll poll], calls.grep(Symbol) - [:guard], "both ESPN slots are fetched"
    assert_equal [:replay, nil], calls.last
  end

  test "the unattended script and the paced one differ only in the pause" do
    driver = Driver.new(io: StringIO.new)
    unattended = driver.replay_script(nil)
    paced = driver.replay_script(4)

    refute_match(/^\s*sleep\b/, unattended, "an unattended replay must not pause")
    assert_match(/^\s*sleep 4\.0$/, paced)
    strip = ->(s) { s.lines.grep_v(/^\s*(sleep\b|# unattended: no pause)/).join }
    assert_equal strip.call(paced), strip.call(unattended),
                 "the per-play chain must be the same code whatever the pace"
  end

  test "neither script carries a shell-expandable name" do
    driver = Driver.new(io: StringIO.new)

    [nil, 4, 0.5].each do |pace|
      refute_match TurfMonster::QaRehearsal::RemoteRunner::SHELL_EXPANDABLE, driver.replay_script(pace)
    end
  end

  test "a failed catch-up check on the dyno stops the step: heroku run passes the exit code through" do
    driver = Driver.new(io: StringIO.new)
    argv = nil
    driver.define_singleton_method(:system) { |*args| argv = args; false }

    assert_raises(Driver::StepError) { driver.replay(nil) }
    assert_includes argv, "--exit-code", "without it heroku run exits 0 whatever the dyno returned"
  end
end
