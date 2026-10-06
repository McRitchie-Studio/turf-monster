require "test_helper"

# [unit] ExperimentEvent.record: one row per visitor per variant per event per
# day, a closed list of events, never a raise; and the retention prune.
class ExperimentEventTest < ActiveSupport::TestCase
  VISITOR = "0f8fad5b-d9cb-469f-a165-70867728950e".freeze

  def record(**overrides)
    ExperimentEvent.record(**{ experiment_slug: "turf-monster-v2", variant_key: "control",
                               event: "visit", visitor_id: VISITOR }.merge(overrides))
  end

  test "records once per visitor, variant, event and day" do
    assert record
    assert record, "a duplicate answers true: it is already counted"
    assert_equal 1, ExperimentEvent.count

    record(event: "cta:play")
    record(variant_key: "fantasy-football")
    record(at: 1.day.from_now)
    assert_equal 4, ExperimentEvent.count
  end

  test "keeps the normalized reference the visitor carried" do
    record(reference: "  TikTok-Bio ")
    assert_equal "tiktok-bio", ExperimentEvent.sole.reference
  end

  test "refuses an event outside the closed list, and blanks" do
    refute record(event: "cta:anything")
    refute record(event: "visit; drop table")
    refute record(visitor_id: "")
    refute record(variant_key: nil)
    assert_equal 0, ExperimentEvent.count
  end

  test "the CTA names map to their events" do
    assert_equal "cta:play", ExperimentEvent.cta_event("play")
    assert_equal "cta:notify", ExperimentEvent.cta_event("notify")
    assert_equal "cta:watch_live", ExperimentEvent.cta_event("watch_live")
    assert_nil ExperimentEvent.cta_event("other")
  end

  test "a database failure answers false and is reported, never raised" do
    ExperimentEvent.stub(:insert, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      assert_difference("ErrorLog.count", 1) { refute record }
    end
  end

  test "prune deletes rows older than the retention" do
    record(at: (ExperimentEvent::RETENTION + 1.day).ago)
    record
    assert_equal 1, ExperimentEvent.prune
    assert_equal 1, ExperimentEvent.count
  end
end
