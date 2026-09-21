# Where a pull-based sync got to, per source.
#
# One row per source, so a partial run RESUMES rather than restarting from the
# beginning of a 2,896-row feed. The watermark is COMPOUND — (updated_at, id) —
# because paging on a timestamp alone silently drops every row sharing a
# boundary second, which a bulk import produces by the thousand.
class SyncCursor < ApplicationRecord
  STATUSES = %w[ok failed skipped].freeze

  validates :source, presence: true, uniqueness: true

  def self.for(source) = find_or_create_by!(source: source)

  # nil means "never synced", and a nil watermark IS the full rebuild — there
  # is no separate mode to get wrong.
  def advance!(updated_at:, id:, rows_seen:, rows_written:)
    update!(watermark_updated_at: updated_at, watermark_id: id,
            last_run_at: Time.current, last_status: "ok",
            rows_seen: rows_seen, rows_written: rows_written)
  end

  def record_failure!(detail)
    update!(last_run_at: Time.current, last_status: "failed", detail: detail.to_s[0, 500])
  end

  def record_skip!(detail)
    update!(last_run_at: Time.current, last_status: "skipped", detail: detail.to_s[0, 500])
  end
end
