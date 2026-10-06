# The "Weeks 7-9 is live" email, sent by hand from
# /admin/drop_signups/announcement. Nothing schedules it.
#
# WHO: the current drop's list (NextSlateDrop::SLATE_KEY) minus anyone already
# announced to (notified_at) or unsubscribed (unsubscribed_at) —
# DropSignup.announceable. The admin page shows that exact count, and the send
# refuses unless the operator typed the same number back, so the count they
# confirmed is the count that was true when they pressed Send.
#
# WHEN: not before NextSlateDrop.drops_at unless the operator ticks "send early".
#
# ONCE: the send only enqueues DropAnnouncementJob. Each row is then claimed
# atomically (DropSignup#deliver_announcement!), so a double-click, two admins,
# a job retry or two jobs at once still mail every address at most once.
#
# PROGRESS reads the rows back: claimed (notified_at set) splits into sent /
# failed / queued by the EmailDelivery outbox row each claim was recorded with,
# and "stranded" is a claim with no outbox row (the process died between the
# claim and the queue) — rare, listed so it is never silent.
class DropAnnouncement
  Refusal = Class.new(StandardError)

  Progress = Data.define(:claimed, :sent, :failed, :queued, :stranded)

  attr_reader :slate_key

  def initialize(slate_key: NextSlateDrop::SLATE_KEY)
    @slate_key = slate_key
  end

  def recipients
    DropSignup.announceable(slate_key)
  end

  def recipient_count
    recipients.count
  end

  def dropped?(now = Time.current)
    NextSlateDrop.dropped?(now)
  end

  # Raises Refusal (with the operator-facing reason) or enqueues the job.
  def send!(confirm_count:, early: false, now: Time.current)
    raise Refusal, "Only the current drop (#{NextSlateDrop::SLATE_KEY}) can be announced." unless slate_key == NextSlateDrop::SLATE_KEY
    raise Refusal, "#{NextSlateDrop::LABEL} hasn't dropped yet. Tick \"Send early\" to send anyway." if !dropped?(now) && !early

    count = recipient_count
    raise Refusal, "Nobody is left to announce to." if count.zero?
    unless confirm_count.to_s.strip == count.to_s
      raise Refusal, "Type #{count} (the recipient count) to confirm. The count may have changed since the page loaded."
    end

    DropAnnouncementJob.perform_later(slate_key)
    count
  end

  def progress
    claimed = DropSignup.for_slate(slate_key).where.not(notified_at: nil)
    joined  = claimed.joins(:announcement_delivery)
    Progress.new(
      claimed:  claimed.count,
      sent:     joined.where(email_deliveries: { sent: true }).count,
      failed:   joined.where(email_deliveries: { sent: false }).where.not(email_deliveries: { error: [nil, ""] }).count,
      queued:   joined.where(email_deliveries: { sent: false, error: [nil, ""] }).count,
      stranded: claimed.where(announcement_delivery_id: nil).count
    )
  end
end
