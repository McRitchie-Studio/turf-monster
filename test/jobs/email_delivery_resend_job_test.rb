require "test_helper"

# The sweeper that re-drives stranded outbox rows.
#
# THE FAILURE IT EXISTS FOR, measured on mainnet 2026-09-07: settling
# turf-totals-alpha-contest-v1 paid a real winner $100 and left their
# winner email at sent=false, sent_at=nil and error=nil, while the other
# winner's row — created in the same second — sent fine. Sidekiq held nothing:
# enqueued 0, retry 0, dead 0. No retry was coming, and a player who had been
# paid would never have been told.
#
# The case that MOTIVATED it is the silent one: a row with no error and no job is
# nobody's problem. The sweep shipped WIDER than that on purpose — an errored row
# is swept too ("sweeps a stranded row that recorded an error" below), because
# Sidekiq's ladder does exhaust and a provider outage would otherwise never
# recover. Scope lives in the job's own comment; keep the two in step.
class EmailDeliveryResendJobTest < ActiveJob::TestCase
  def row(created_at:, sent: false, error: nil, to: "x@example.com")
    EmailDelivery.create!(
      mailer: "ContestMailer", action: "winnings", email_key: "ContestMailer#winnings",
      to: to, sent: sent, error: error,
      args: ActiveJob::Arguments.serialize([]), kwargs: ActiveJob::Arguments.serialize([{}]).first,
      created_at: created_at
    )
  end

  setup do
    EmailDelivery.delete_all
    # Capture is OFF in this env, but assert rather than assume: the capture
    # guard is the difference between a sweep and an infinite loop, and a test
    # that silently ran with capture ON would pass while proving nothing.
    assert_not Studio.local_email_capture?
  end

  test "re-enqueues a row stranded past the threshold" do
    stranded = row(created_at: 45.minutes.ago)

    assert_enqueued_with(job: EmailDeliveryJob, args: [stranded.id]) do
      assert_equal 1, EmailDeliveryResendJob.perform_now
    end
  end

  # THE POINT OF THE THRESHOLD. A row is created and its job enqueued in the
  # same breath, so a young unsent row is in flight, not stranded. Sweeping it
  # would put a second copy of a real email in someone's inbox.
  test "leaves a young row alone so an in-flight delivery is not double-sent" do
    row(created_at: 2.minutes.ago)

    assert_no_enqueued_jobs only: EmailDeliveryJob do
      assert_equal 0, EmailDeliveryResendJob.perform_now
    end
  end

  test "ignores rows that already sent" do
    row(created_at: 45.minutes.ago, sent: true)

    assert_no_enqueued_jobs only: EmailDeliveryJob do
      assert_equal 0, EmailDeliveryResendJob.perform_now
    end
  end

  # A row that FAILED loudly is already inside Sidekiq's retry machinery, but it
  # is still unsent, and leaving it out would mean a permanent outage never
  # recovers once its retries are exhausted. Swept like any other.
  test "sweeps a stranded row that recorded an error" do
    stranded = row(created_at: 45.minutes.ago, error: "Net::SMTPServerBusy")

    assert_enqueued_with(job: EmailDeliveryJob, args: [stranded.id]) do
      EmailDeliveryResendJob.perform_now
    end
  end

  test "the threshold is overridable for an operator running it by hand" do
    recent = row(created_at: 5.minutes.ago)

    assert_enqueued_with(job: EmailDeliveryJob, args: [recent.id]) do
      assert_equal 1, EmailDeliveryResendJob.perform_now(stranded_after_minutes: 1)
    end
  end

  test "sweeps every stranded row, not just the first" do
    3.times { |i| row(created_at: 45.minutes.ago, to: "w#{i}@example.com") }

    assert_enqueued_jobs 3, only: EmailDeliveryJob do
      assert_equal 3, EmailDeliveryResendJob.perform_now
    end
  end

  # END TO END on the exact shape that was missed, built through the REAL
  # producer rather than a hand-made row: EmailDelivery.deliver is what records
  # the intent, so its serialized args are the ones deliver_now! has to be able
  # to rebuild a mailer from. A synthetic row with empty args passes a sweeper
  # test while proving nothing — it fails inside the mailer, not the sweep.
  test "a stranded winner email reaches sent after a tick" do
    entry = contests(:one).entries.create!(
      user: users(:alex), status: "complete", rank: 1, payout_cents: 4500, score: 1.0
    )
    stranded = nil
    perform_enqueued_jobs(only: EmailDeliveryJob) do
      stranded = EmailDelivery.deliver(ContestMailer, :winnings, entry, to: users(:alex).email)
    end
    # Strand it exactly as production did: unsent, no error, nothing queued.
    stranded.update!(sent: false, sent_at: nil, error: nil, created_at: 45.minutes.ago)

    perform_enqueued_jobs(only: EmailDeliveryJob) { EmailDeliveryResendJob.perform_now }

    assert stranded.reload.sent?, "the sweep should have driven the row to sent"
    assert_not_nil stranded.sent_at
    assert_nil stranded.error
  end

  # --- the bounds, each a blocking review finding on PR #611 ---

  # MEASURED, not theoretical. Under LOCAL_EMAIL_CAPTURE=1 (every agent worktree
  # stack) EmailDelivery.deliver writes the row and never enqueues, and
  # deliver_now! returns early setting only `error` — so the row can NEVER reach
  # sent. That is exactly the signature this job hunts, which made it a
  # non-terminating loop: a reviewer measured the same row re-queued on three
  # consecutive ticks, and the cron loads wherever Sidekiq boots.
  test "no-ops entirely where local email capture is on" do
    row(created_at: 45.minutes.ago)

    Studio.stub(:local_email_capture?, true) do
      assert_no_enqueued_jobs only: EmailDeliveryJob do
        assert_equal 0, EmailDeliveryResendJob.perform_now
      end
    end
  end

  # A floor-only scope sweeps the whole table on its first tick. email_deliveries
  # is never pruned and dates to 2026-06-10, so without a ceiling the first
  # production run could mail months-old "you won $100" notices — worse than the
  # incident it fixes, and impossible to unsend.
  test "leaves rows older than the sweep window for a human" do
    ancient = row(created_at: 120.days.ago)

    assert_no_enqueued_jobs only: EmailDeliveryJob do
      assert_equal 0, EmailDeliveryResendJob.perform_now
    end
    assert_not ancient.reload.sent?
  end

  test "a backlog drains across ticks instead of firing in one pass" do
    (EmailDeliveryResendJob::BATCH_LIMIT + 5).times { |i| row(created_at: (2 + i).hours.ago) }

    assert_equal EmailDeliveryResendJob::BATCH_LIMIT, EmailDeliveryResendJob.perform_now
  end

  # ORDER ONLY MATTERS WHERE THE CAP BITES, which is what the first version of
  # this test missed: with two rows and a limit of 100 both are enqueued whichever
  # way they are sorted, so it passed against newest-first too. Overfill the
  # batch, then the sweep has to CHOOSE — and the choice is the behaviour.
  test "the oldest stranded rows are the ones recovered first" do
    limit  = EmailDeliveryResendJob::BATCH_LIMIT
    rows   = (1..(limit + 5)).map { |i| row(created_at: (i + 1).hours.ago, to: "w#{i}@example.com") }
    oldest = rows.sort_by(&:created_at).first(limit).map(&:id)

    EmailDeliveryResendJob.perform_now

    enqueued = enqueued_jobs.select { |j| j["job_class"] == "EmailDeliveryJob" }
                            .map { |j| j["arguments"].first }
    assert_equal oldest.sort, enqueued.sort,
      "the batch should be the oldest #{limit} rows, not the newest"
  end

  # 0 is truthy in Ruby, so a bare `|| STRANDED_AFTER` accepts it and the
  # in-flight guard disappears — the by-hand path is the documented one, so it
  # must not be able to double-send.
  test "an override cannot collapse the in-flight guard" do
    row(created_at: 10.seconds.ago)

    assert_no_enqueued_jobs only: EmailDeliveryJob do
      assert_equal 0, EmailDeliveryResendJob.perform_now(stranded_after_minutes: 0)
    end
  end
end
