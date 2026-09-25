require "test_helper"

# [unit] The cursor is the ONLY durable record of what a sync run did. Every
# property here is about one thing: a run that refused rows must not be
# indistinguishable from a run that found nothing wrong.
class SyncCursorTest < ActiveSupport::TestCase
  setup { SyncCursor.delete_all }

  def cursor = SyncCursor.for("studio_athletes")

  # THE CONSTANT MUST NOT LIE. It was `%w[ok failed skipped]` while the service
  # already produced a fourth outcome, and because nothing validated against it
  # the constant was documentation that had silently gone out of date — the
  # worst kind, since a reader checks it instead of the writers.
  #
  # Measured BEHAVIOURALLY, by calling every writer, rather than by scanning the
  # source for `last_status: "..."` literals: once `advance!` takes its status as
  # an argument the literals stop being in this file, and a scan would quietly
  # narrow to the two that remain while a fifth outcome drifted in unnamed.
  test "every status the model can write is a member of STATUSES" do
    c = cursor
    produced = []

    c.advance!(updated_at: Time.current, id: 1, rows_seen: 1, rows_written: 1)
    produced << c.last_status
    c.advance!(updated_at: Time.current, id: 1, rows_seen: 1, rows_written: 1,
               status: "ok_with_collisions", detail: "p1-remote refused")
    produced << c.last_status
    c.record_failure!("boom")
    produced << c.last_status
    c.record_skip!("no secret")
    produced << c.last_status

    assert_equal 4, produced.uniq.length,
                 "the control: the four writers must actually produce four DISTINCT outcomes — " \
                 "got #{produced.inspect}"
    produced.each do |status|
      assert_includes SyncCursor::STATUSES, status,
                      "#{status.inspect} is written by the model but missing from STATUSES"
    end
  end

  # Four sibling models in this repo (StripePurchase, CoinflowPurchase,
  # PaypalPurchase, AeropayPurchase) pair a STATUSES constant with an inclusion
  # validation. This one did not, so the constant constrained nothing.
  test "last_status is validated against STATUSES" do
    c = cursor
    c.last_status = "definitely-not-a-status"

    assert_not c.valid?, "an unknown status must not be storable"
    assert c.errors.of_kind?(:last_status, :inclusion)
  end

  test "every member of STATUSES is actually storable" do
    SyncCursor::STATUSES.each do |status|
      c = cursor
      c.last_status = status
      assert c.valid?, "#{status.inspect} is in STATUSES but fails validation"
    end
  end

  test "advance! records the status it is given, not a hard-coded ok" do
    cursor.advance!(updated_at: Time.current, id: 7, rows_seen: 3, rows_written: 1,
                    status: "ok_with_collisions", detail: "p1-remote refused")

    assert_equal "ok_with_collisions", cursor.last_status
    assert_equal "p1-remote refused", cursor.detail
  end

  test "advance! still defaults to ok for a clean run" do
    cursor.advance!(updated_at: Time.current, id: 7, rows_seen: 3, rows_written: 3)

    assert_equal "ok", cursor.last_status
  end

  # A STALE DETAIL IS A LYING STATUS LINE. `advance!` never cleared `detail`, so
  # a run that failed and then succeeded left the failure text on the cursor —
  # and `studio:sync_status` prints `detail` whenever it is present.
  test "a clean run clears a previous run's detail" do
    cursor.record_failure!("studio unreachable: SocketError")
    assert_equal "studio unreachable: SocketError", cursor.detail, "the control: the failure was recorded"

    cursor.advance!(updated_at: Time.current, id: 1, rows_seen: 1, rows_written: 1)

    assert_nil cursor.detail, "a clean run must not keep reporting the last failure"
  end
end
