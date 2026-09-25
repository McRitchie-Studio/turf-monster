# Where a pull-based sync got to, per source.
#
# One row per source, so a partial run RESUMES rather than restarting from the
# beginning of a 2,896-row feed. The watermark is COMPOUND — (updated_at, id) —
# because paging on a timestamp alone silently drops every row sharing a
# boundary second, which a bulk import produces by the thousand.
class SyncCursor < ApplicationRecord
  # EVERY outcome a run can end in, including the one the service was already
  # producing. `ok_with_collisions` is a run that completed and REFUSED rows:
  # not a failure (the refusal guard working as designed) and emphatically not
  # an `ok`, which is what the cursor recorded until 2026-09-24.
  #
  # The inclusion validation is the half that was missing. Nothing referenced
  # this constant, so it constrained nothing and the column happily stored any
  # string — four sibling models here (StripePurchase, CoinflowPurchase,
  # PaypalPurchase, AeropayPurchase) pair a STATUSES with exactly this
  # validation, and this model was the odd one out.
  STATUSES = %w[ok ok_with_collisions failed skipped].freeze

  validates :source, presence: true, uniqueness: true
  # allow_nil: a cursor is created before its first run, when "never synced" is
  # the honest answer and `nil` is what `studio:sync_status` prints as "-".
  validates :last_status, inclusion: { in: STATUSES }, allow_nil: true

  def self.for(source) = find_or_create_by!(source: source)

  # nil means "never synced", and a nil watermark IS the full rebuild — there
  # is no separate mode to get wrong.
  #
  # `status` is an ARGUMENT, not a literal. It was hard-coded to "ok", so a run
  # that refused rows recorded itself as a clean one and the refusal survived
  # only in the Result object, which dies with the process.
  #
  # `detail` is written on EVERY advance, nil included, because it is not
  # additive: it describes THIS run. Leaving it alone let a failure's text
  # outlive the failure — a run that failed and then succeeded kept
  # "studio unreachable: SocketError" on the cursor, and `studio:sync_status`
  # prints `detail` whenever it is present, so the status line reported a
  # problem the last run had not had. Truncated like the other writers: the
  # column is durable and a collision list grows with the feed.
  def advance!(updated_at:, id:, rows_seen:, rows_written:, status: "ok", detail: nil)
    update!(watermark_updated_at: updated_at, watermark_id: id,
            last_run_at: Time.current, last_status: status,
            rows_seen: rows_seen, rows_written: rows_written,
            detail: detail&.to_s&.slice(0, 500))
  end

  def record_failure!(detail)
    update!(last_run_at: Time.current, last_status: "failed", detail: detail.to_s[0, 500])
  end

  def record_skip!(detail)
    update!(last_run_at: Time.current, last_status: "skipped", detail: detail.to_s[0, 500])
  end
end
