require "test_helper"

# [unit] Contest::Reveal: the default reveal_at, the readiness gate, the
# idempotent flip, the hold, and the 24-hour refusal, each with its control.
class ContestRevealTest < ActiveSupport::TestCase
  def build(starts_at: 10.days.from_now, **attrs)
    Contest.new({ name: "Reveal #{SecureRandom.hex(3)}", slate: slates(:one), contest_type: "standard",
                  starts_at: starts_at, user: users(:alex), status: "open", max_entries: 29 }.merge(attrs))
  end

  # Open, on chain, priced (slates(:one) ranks and prices every team), coming
  # soon, with its reveal already past.
  def ready(reveal_at: 1.minute.ago, **attrs)
    build(coming_soon: true, reveal_at: reveal_at, **attrs).tap do |c|
      c.save!
      c.update_columns(onchain_contest_id: EnteredOnchain.random_wallet)
    end
  end

  test "a new contest's reveal_at defaults to seven days before its lock" do
    contest = build.tap(&:save!)

    assert_equal 7.days, Contest::Reveal::REVEAL_LEAD
    assert_in_delta (contest.locks_at - 7.days).to_f, contest.reveal_at.to_f, 1
  end

  test "control: an explicit reveal_at is kept" do
    at = 2.days.from_now.change(usec: 0)
    assert_equal at, build(reveal_at: at).tap(&:save!).reveal_at
  end

  test "reveal_at at or after the lock is refused" do
    contest = build(reveal_at: 11.days.from_now)

    refute contest.valid?
    assert_includes contest.errors[:reveal_at], "must be before the lock time"
  end

  test "a due, ready contest reveals once, and a second run changes nothing" do
    contest = ready

    assert contest.reveal!
    refute contest.reload.coming_soon?
    refute contest.reveal!, "the flip is idempotent"
  end

  test "control: not before reveal_at" do
    contest = ready(reveal_at: 1.hour.from_now)

    refute contest.reveal!
    assert contest.reload.coming_soon?
    assert contest.reveal!(2.hours.from_now)
  end

  test "control: not when unpriced" do
    contest = ready
    slates(:one).slate_matchups.first.update_columns(rank: nil)

    assert_equal "unpriced", contest.reveal_blocker
    refute contest.reveal!
    assert contest.reload.coming_soon?
  end

  test "control: not when a team has no Turf Score" do
    contest = ready
    slates(:one).slate_matchups.first.update_columns(turf_score: nil)

    refute contest.reveal!
    assert contest.reload.coming_soon?
  end

  test "control: not when not on chain" do
    contest = ready.tap { |c| c.update_columns(onchain_contest_id: nil) }

    assert_equal "not on chain", contest.reveal_blocker
    refute contest.reveal!
    assert contest.reload.coming_soon?
  end

  test "control: not when held" do
    contest = ready(coming_soon_hold: true)

    refute contest.reveal!
    assert contest.reload.coming_soon?
  end

  test "control: not when cancelled or not open" do
    cancelled = ready.tap { |c| c.update_columns(onchain_cancelled: true) }
    pending = ready.tap { |c| c.update_columns(status: "pending") }

    refute cancelled.reveal!
    refute pending.reveal!
    assert [cancelled, pending].all? { |c| c.reload.coming_soon? }
  end

  test "control: a legacy contest with no reveal_at is never revealed" do
    contest = ready.tap { |c| c.update_columns(reveal_at: nil) }

    refute contest.reveal_due?
    refute contest.reveal!
    assert contest.reload.coming_soon?
  end

  test "a reveal loses the race to an admin turning Hold on" do
    contest = ready
    Contest.where(id: contest.id).update_all(coming_soon_hold: true)

    refute contest.reveal!, "the stale in-memory row must not flip a held contest"
    assert contest.reload.coming_soon?
  end

  test "saving Coming Soon within 24 hours of the lock is refused with a reason" do
    contest = build(starts_at: 20.hours.from_now, coming_soon: true)

    refute contest.save
    assert_match(/locks within 24 hours/, contest.errors[:base].first)
    assert_match(/Hold/, contest.errors[:base].first)
  end

  test "control: Hold saves fine inside 24 hours" do
    assert build(starts_at: 20.hours.from_now, coming_soon: true, coming_soon_hold: true).save
  end

  test "control: Coming Soon saves fine more than 24 hours out, and an open contest saves inside 24 hours" do
    assert build(starts_at: 25.hours.from_now, coming_soon: true).save
    assert build(starts_at: 20.hours.from_now, coming_soon: false).save
  end

  test "turning Coming Soon on, or Hold off, inside 24 hours is refused on update" do
    open = build(starts_at: 20.hours.from_now).tap(&:save!)
    held = build(starts_at: 20.hours.from_now, coming_soon: true, coming_soon_hold: true).tap(&:save!)

    refute open.update(coming_soon: true)
    refute held.update(coming_soon_hold: false)
  end

  test "control: a write that does not touch the flag, hold or lock is not refused" do
    contest = build(starts_at: 3.days.from_now, coming_soon: true).tap(&:save!)
    contest.update_columns(starts_at: 1.hour.ago) # a legacy row already in the state

    assert contest.update(tagline: "Still saves"), contest.errors.full_messages.to_sentence
  end

  test "the admin form reads and writes reveal_at in Denver time" do
    contest = build
    contest.reveal_at_local = "2026-10-30T09:30"

    assert_equal Time.utc(2026, 10, 30, 15, 30), contest.reveal_at
    assert_equal "2026-10-30T09:30", contest.reveal_at_local
    contest.reveal_at_local = ""
    assert_nil contest.reveal_at
  end

  test "scheduled_reveal_at is reveal_at only while coming soon and not held" do
    at = 2.days.from_now.change(usec: 0) # the column keeps microseconds; Time.now carries nanoseconds
    assert_equal at, build(coming_soon: true, reveal_at: at).scheduled_reveal_at
    assert_nil build(coming_soon: true, coming_soon_hold: true, reveal_at: at).scheduled_reveal_at
    assert_nil build(coming_soon: false, reveal_at: at).scheduled_reveal_at
  end
end
