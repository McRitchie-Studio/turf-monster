require "test_helper"
require "rake"

# studio:sync_athletes / studio:sync_status (lib/tasks/studio_sync.rake).
#
# THE EXIT CODE IS THE CONTRACT a future cadence inherits, and nothing
# schedules this task yet — so these tests pin which outcomes are allowed to
# redden a run and which are only allowed to be loud.
class StudioSyncTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("studio:sync_athletes")
    Athlete.delete_all
    Person.where(last_name: "Remote").delete_all
    SyncCursor.delete_all
    ErrorLog.delete_all
    ENV["AGENT_API_SECRET"] = "shh"
  end

  teardown do
    ENV.delete("AGENT_API_SECRET")
    ENV.delete("FULL")
  end

  def invoke(name)
    task = Rake::Task["studio:#{name}"]
    task.reenable
    capture_io { task.invoke }
  end

  # The two production pairs from the 2026-09-24 run.
  PAIRS = [ [ 1, "00-0038661", "00-0038602" ], [ 2, "00-0036171", "00-0028946" ] ].freeze

  def collide!
    PAIRS.each do |n, ours, _theirs|
      person = Person.create!(first_name: "P#{n}", last_name: "Remote")
      assert_equal "p#{n}-remote", person.slug, "the control: the fixture must actually collide"
      a = Athlete.new(person_slug: person.slug, sport: "football")
      a.syncing = true
      a.gsis_id = ours
      a.save!
    end
  end

  def stub_result(status:, collisions: [])
    result = Studio::SyncAthletes::Result.new(rows_seen: 2, rows_written: 0, pages: 1,
                                              status: status, collisions: collisions)
    fake = Object.new
    fake.define_singleton_method(:call) { result }
    Studio::SyncAthletes.stub(:new, ->(*_a, **_k) { fake }) do
      yield
    end
  end

  # A REFUSAL MUST NOT ABORT. It is the guard working as designed, the replica
  # cannot resolve it, and the condition repeats on every run — so a non-zero
  # exit would be permanently red rather than newsworthy.
  test "a collided run is loud but exits zero" do
    collide!
    rows = PAIRS.map do |n, _o, theirs|
      { "gsis_id" => theirs, "person_slug" => "p#{n}-remote", "first_name" => "P#{n}",
        "last_name" => "Remote", "sport" => "football", "updated_at" => Time.current.iso8601(6) }
    end
    page = { "data" => rows, "meta" => { "more" => false, "next_updated_since" => rows.last["updated_at"], "next_after_id" => 2 } }

    svc = Studio::SyncAthletes.new(secret: "shh")
    svc.define_singleton_method(:authenticate) { "tok" }
    queue = [ page ]
    svc.define_singleton_method(:fetch) { |_t, _s, _a| queue.shift || { "data" => [], "meta" => { "more" => false } } }

    out = err = nil
    Studio::SyncAthletes.stub(:new, ->(*_a, **_k) { svc }) do
      # SystemExit is NOT a StandardError, so `assert_nothing_raised` would let
      # an abort kill the whole runner instead of failing this test by name.
      # Catch it explicitly and assert on the exit status.
      exited = nil
      begin
        out, err = invoke("sync_athletes")
      rescue SystemExit => e
        exited = e
      end
      assert_nil exited,
                 "a designed refusal must not abort the task (exited #{exited&.status})"
    end

    assert_match(/ok_with_collisions/, out, "the control: the run actually collided")
    assert_match(/COLLISIONS: 2 row\(s\) REFUSED/, err)
    assert_match(%r{/admin/error_logs}, err, "the operator needs the durable copy's address")
    assert_equal 2, ErrorLog.count, "and the durable copies must exist"
  end

  # THE OTHER SIDE OF THE SAME CONTRACT. A provider that could not be read IS a
  # failure and must still abort non-zero — the comment above #call used to call
  # this a "skip", which it has never been.
  test "a failed run still aborts non-zero" do
    stub_result(status: "failed") do
      assert_raises(SystemExit, "an unreadable provider must redden the run") do
        capture_io { Rake::Task["studio:sync_athletes"].tap(&:reenable).invoke }
      end
    end
  end

  test "a skipped run exits zero" do
    stub_result(status: "skipped") do
      exited = nil
      begin
        invoke("sync_athletes")
      rescue SystemExit => e
        exited = e
      end
      assert_nil exited, "a stack that does not sync must not redden a deploy (exited #{exited&.status})"
    end
  end

  # ACCEPTANCE: the status task shows what the last run refused. Before this,
  # the first production run refused two rows and this task printed "(ok)".
  test "sync_status reports what the last run refused" do
    SyncCursor.for(Studio::SyncAthletes::SOURCE).advance!(
      updated_at: Time.current, id: 2, rows_seen: 2, rows_written: 0,
      status: "ok_with_collisions",
      detail: "2 row(s) REFUSED — p1-remote (ours 00-0038661 / master 00-0038602)"
    )

    out, = invoke("sync_status")

    assert_match(/ok_with_collisions/, out, "the status line must not read (ok)")
    assert_match(/REFUSED/, out)
    assert_match(/p1-remote/, out, "the refused slug has to be visible")
    assert_match(/00-0038661/, out, "and both league ids, since only the master can resolve it")
    assert_match(/00-0038602/, out)
    assert_match(%r{/admin/error_logs}, out)
  end

  test "sync_status on a clean run says nothing about refusals" do
    SyncCursor.for(Studio::SyncAthletes::SOURCE).advance!(
      updated_at: Time.current, id: 1, rows_seen: 1, rows_written: 1
    )

    out, = invoke("sync_status")

    assert_match(/\(ok\)/, out, "the control: this run was clean")
    assert_no_match(/REFUSED/, out, "a clean run must not cry refusal")
  end
end
