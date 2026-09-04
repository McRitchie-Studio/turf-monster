# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# THE FIXTURE CLOCK, and the property that makes a step safe to re-run.
#
# Step 1 nudges an already-played week into the future so the board is
# pickable; something has to put it back. Review found two ways that was
# broken and neither was visible to any test: the paced path skipped the
# unshift entirely, and once wired up it was not idempotent — the shift was
# recorded once and never spent, so a second run moved the week to real−S and a
# third to real−2S, walking the fixture backwards into the past a run at a time.
#
# The reset path survived that by accident, because the ESPN poll re-anchors
# kickoff_at seconds later. The paced path skips that poll. Accidents are not
# guards.
class QaRehearsalUnshiftTest < ActiveSupport::TestCase
  Driver = TurfMonster::QaRehearsal::Driver

  # Records the scripts it is asked to run so the test can assert on them.
  class FakeRemote
    attr_reader :scripts

    def initialize = @scripts = []

    def call(source)
      @scripts << source
      { "unshifted" => 16, "goals" => 129 }
    end
  end

  def driver_with(manifest_data, remote: FakeRemote.new)
    dir = Dir.mktmpdir
    manifest = TurfMonster::QaRehearsal::Manifest.new(dir: dir)
    manifest.write(manifest_data)

    driver = Driver.new(io: StringIO.new)
    driver.define_singleton_method(:guard!) { { app: "turf-monster-qa" } }
    driver.define_singleton_method(:remote) { remote }
    driver.define_singleton_method(:manifest) { manifest }
    [driver, manifest, remote]
  end

  test "a positive shift is applied once and then SPENT" do
    driver, manifest, remote = driver_with({ "contest_slug" => "c", "kickoff_shift_seconds" => 7200 })

    driver.send(:unshift_fixture, 7200)

    assert_equal 1, remote.scripts.size, "the shift should have been applied"
    assert_match(/kickoff_at - 7200.seconds/, remote.scripts.first)
    assert_equal 0, manifest.read["kickoff_shift_seconds"],
                 "the shift must be recorded as spent, or a re-run applies it again"
  end

  # THE BUG, stated as a test: run it twice and the clock must move once.
  test "running it again does nothing, because the shift is already spent" do
    driver, manifest, remote = driver_with({ "contest_slug" => "c", "kickoff_shift_seconds" => 7200 })

    driver.send(:unshift_fixture, manifest.read["kickoff_shift_seconds"].to_i)
    driver.send(:unshift_fixture, manifest.read["kickoff_shift_seconds"].to_i)

    assert_equal 1, remote.scripts.size,
                 "the fixture was moved twice — the second run walks it into the past"
  end

  test "a zero or absent shift is a no-op" do
    driver, _manifest, remote = driver_with({ "contest_slug" => "c" })

    driver.send(:unshift_fixture, 0)
    driver.send(:unshift_fixture, -5)

    assert_empty remote.scripts
  end

  # THE CALL SITE, not just the method. Deleting the call from the paced path is
  # exactly what review found, and it left every other test green.
  test "the paced path puts the clock back before replaying" do
    driver, _manifest, _remote = driver_with({ "contest_slug" => "c", "kickoff_shift_seconds" => 3600 })

    unshifted = []
    driver.define_singleton_method(:unshift_fixture) { |s| unshifted << s }
    driver.define_singleton_method(:slate_already_scored?) { true }
    driver.define_singleton_method(:lock_contest) { |_slug| nil }
    driver.define_singleton_method(:replay) { |_pace| :replayed }

    assert_equal :replayed, driver.play_preseason(pace: 4)
    assert_equal [3600], unshifted, "the paced path must put the fixture clock back"
  end

  # And the reset path must use the SAME method, not a second inline copy —
  # which is what the code claimed while two implementations sat side by side.
  test "the reset path uses the same unshift, not its own copy" do
    driver, _manifest, remote = driver_with({ "contest_slug" => "c", "kickoff_shift_seconds" => 3600 })

    unshifted = []
    driver.define_singleton_method(:unshift_fixture) { |s| unshifted << s }
    driver.define_singleton_method(:slate_already_scored?) { false }
    driver.define_singleton_method(:lock_contest) { |_slug| nil }
    driver.define_singleton_method(:system) { |*_args| true }

    driver.play_preseason(reset: true, pace: 0)

    assert_equal [3600], unshifted, "the reset path must go through unshift_fixture too"
    refute(remote.scripts.any? { |s| s.match?(/kickoff_at - /) },
           "the reset script still carries its own inline unshift")
  end
end
