# frozen_string_literal: true

require "test_helper"

# The manifest is what lets the five steps be five COMMANDS rather than one.
class QaRehearsalManifestTest < ActiveSupport::TestCase
  Manifest = TurfMonster::QaRehearsal::Manifest

  setup do
    @dir = Dir.mktmpdir
    @manifest = Manifest.new(dir: @dir)
  end

  teardown { FileUtils.remove_entry(@dir) }

  test "round-trips what step 1 hands to step 2" do
    @manifest.write(contest_slug: "qa-rehearsal-x", picks_required: 6, matchup_ids: [1, 2, 3])

    read = @manifest.read
    assert_equal "qa-rehearsal-x", read["contest_slug"]
    assert_equal [1, 2, 3], read["matchup_ids"]
  end

  # merge, not overwrite: step 4 records the settle transaction onto a manifest
  # step 1 wrote, and losing the contest slug there would strand step 5.
  test "merge keeps what earlier steps recorded" do
    @manifest.write(contest_slug: "qa-rehearsal-x", picks_required: 6)
    @manifest.merge(ptx_slug: "ptx-123")

    read = @manifest.read
    assert_equal "qa-rehearsal-x", read["contest_slug"]
    assert_equal 6, read["picks_required"]
    assert_equal "ptx-123", read["ptx_slug"]
  end

  # Reading with no run in progress must say WHICH step to run, not raise
  # Errno::ENOENT at someone who has not read this file.
  test "reading with no run in progress names the step to run" do
    error = assert_raises(Manifest::MissingError) { @manifest.read }

    assert_match(/step 1/, error.message)
  end

  test "read_or_empty tolerates the same absence" do
    assert_equal({}, @manifest.read_or_empty)
  end
end
