require "test_helper"
require "rake"

# [integration] nfl:players_seed — how a bulk importer REPORTS trouble.
#
# The task used to discard `SeedPlayers#call`'s return value, print every word
# to STDOUT, and exit 0 whatever happened. Its sibling `studio:sync_athletes`
# has always done the opposite (lib/tasks/studio_sync.rake) — STDERR for rows a
# human must resolve, `abort` for a real failure. Two bulk importers in one repo
# disagreeing about that is how the next one learns the wrong lesson from
# whichever it reads first, so these tests pin the agreed contract:
#
#   REFUSED namesake -> STDERR, exit 0. The policy working, not a fault.
#   FAILED row       -> abort, non-zero. Something expected to write did not.
class NflPlayersSeedTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("nfl:players_seed")
    ENV["SKIP_HEADSHOTS"] = "1"
  end

  teardown do
    %w[SKIP_HEADSHOTS VERBOSE MIN_SEASON STATUS].each { |key| ENV.delete(key) }
  end

  # The seeder itself is exercised in test/services/nflverse/seed_players_test.rb.
  # Here it is stubbed to a fixed stats hash so the task's REPORTING is the only
  # thing under test — and so the task does not reach for the live 7MB feed.
  def stub_seeder(stats)
    fake = Object.new
    fake.define_singleton_method(:call) { stats }
    Nflverse::SeedPlayers.stub(:new, ->(**) { fake }) { yield }
  end

  def invoke
    task = Rake::Task["nfl:players_seed"]
    task.reenable
    task.invoke
  end

  test "a clean run stays silent on STDERR and does not abort" do
    out = err = nil
    stub_seeder(Hash.new(0)) { out, err = capture_io { invoke } }

    assert_match(/people:/, out, "the human summary still goes to STDOUT")
    assert_equal "", err, "a clean run must not cry wolf on STDERR"
  end

  # A REFUSAL IS NOT A FAILURE. It needs a human, so it must be loud enough to
  # survive a stdout pipe — but a rebuild that correctly refused a namesake did
  # its job, and reddening it would train an operator to ignore the exit code.
  test "a refused namesake warns on STDERR and still exits zero" do
    stats = Hash.new(0).merge(namesake_collisions_skipped: 2, athletes_created: 9)

    out = err = nil
    assert_nothing_raised do
      stub_seeder(stats) { out, err = capture_io { invoke } }
    end

    assert_match(/NAMESAKES: 2 row\(s\) REFUSED/, err)
    assert_match(/ErrorLog/, err, "STDERR must say where the durable record went")
    assert_no_match(/NAMESAKES/, out, "the refusal belongs on STDERR, not buried in STDOUT")
  end

  # THE FORWARD HAZARD THIS CLOSES. Nothing consumes this task's exit code
  # today — it is in no Procfile release phase and no CI job — so a caller
  # added tomorrow is exactly who this protects.
  test "a failed row aborts with a non-zero exit" do
    stats = Hash.new(0).merge(athletes_failed: 3)

    error = assert_raises(SystemExit) do
      stub_seeder(stats) { capture_io { invoke } }
    end

    assert_not error.success?, "a row this importer meant to write and could not is a failure"
  end

  # The two states are INDEPENDENT: refusals must not mask a failure hiding in
  # the same run, which a single "anything went wrong" branch would have done.
  test "a run with both refusals and failures still aborts" do
    stats = Hash.new(0).merge(namesake_collisions_skipped: 1, athletes_failed: 1)

    error = assert_raises(SystemExit) do
      stub_seeder(stats) { capture_io { invoke } }
    end

    assert_not error.success?
  end
end
