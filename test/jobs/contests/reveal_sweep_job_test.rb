require "test_helper"

# [integration] Contests::RevealSweepJob across the database and ErrorLog: it
# reveals the ready contests, leaves the rest, and raises ONE alert per contest
# still coming soon within a day of its lock, however many ticks run.
class Contests::RevealSweepJobTest < ActiveSupport::TestCase
  def contest(starts_at:, reveal_at: nil, onchain: true, **attrs)
    c = Contest.new({ name: "Sweep #{SecureRandom.hex(3)}", slate: slates(:one), contest_type: "standard",
                      starts_at: 10.days.from_now, user: users(:alex), status: "open", max_entries: 29 }.merge(attrs))
    c.save!
    # Straight to the column: the 24-hour state is refused at save, and the
    # sweep exists for the rows that reach it anyway (a legacy row, a lock
    # that arrived with the flag still on).
    c.update_columns(starts_at: starts_at, reveal_at: reveal_at,
                     onchain_contest_id: (EnteredOnchain.random_wallet if onchain))
    c
  end

  def alerts_for(c)
    ErrorLog.where(target_type: "Contest", target_id: c.id)
  end

  test "reveals a due, ready contest and leaves one that is not due" do
    due = contest(starts_at: 3.days.from_now, reveal_at: 1.minute.ago, coming_soon: true)
    later = contest(starts_at: 9.days.from_now, reveal_at: 2.days.from_now, coming_soon: true)

    stats = Contests::RevealSweepJob.perform_now

    assert_equal 1, stats[:revealed]
    refute due.reload.coming_soon?
    assert later.reload.coming_soon?
  end

  test "alerts once per contest coming soon inside 24 hours of its lock, across ticks" do
    stuck = contest(starts_at: 20.hours.from_now, reveal_at: 1.minute.ago, coming_soon: true, onchain: false)

    assert_difference -> { alerts_for(stuck).count }, 1 do
      3.times { Contests::RevealSweepJob.perform_now }
    end
    alert = alerts_for(stuck).sole
    assert_match(/#{stuck.slug}/, alert.message)
    assert_match(%r{/contests/#{stuck.slug}/edit}, alert.message)
    assert_match(/not on chain/, alert.message)
    assert_equal "Contest::Reveal::ComingSoonAtLockError", alert.inspect_field[/#<([^:]+(?:::[^:]+)*):/, 1]
    assert stuck.reload.coming_soon?, "a contest that is not ready is never revealed to quiet an alert"
  end

  test "a legacy contest that locked while coming soon alerts once" do
    locked = contest(starts_at: 2.days.ago, coming_soon: true)

    assert_difference -> { alerts_for(locked).count }, 1 do
      2.times { Contests::RevealSweepJob.perform_now }
    end
    assert_match(/locked at/, alerts_for(locked).sole.message)
  end

  test "control: no alert for a held contest, one more than a day out, or a graded one" do
    held = contest(starts_at: 20.hours.from_now, coming_soon: true, coming_soon_hold: true)
    far = contest(starts_at: 30.hours.from_now, coming_soon: true)
    graded = contest(starts_at: 2.days.ago, coming_soon: true).tap { |c| c.update_columns(status: "settled") }

    assert_no_difference -> { ErrorLog.where(target_type: "Contest").count } do
      Contests::RevealSweepJob.perform_now
    end
    assert [held, far, graded].all? { |c| c.reload.coming_soon? }
  end

  test "moving the lock re-arms the alert" do
    c = contest(starts_at: 20.hours.from_now, coming_soon: true, onchain: false)
    Contests::RevealSweepJob.perform_now
    assert c.reload.coming_soon_alerted_at

    c.update!(starts_at: 5.days.from_now)

    assert_nil c.reload.coming_soon_alerted_at
  end

  test "a failed page releases the claim so the next tick retries" do
    c = contest(starts_at: 20.hours.from_now, coming_soon: true, onchain: false)

    ErrorLog.stub(:capture!, ->(e) { raise "pager down" if e.is_a?(Contest::Reveal::ComingSoonAtLockError); ErrorLog.new }) do
      Contests::RevealSweepJob.perform_now
    end
    assert_nil c.reload.coming_soon_alerted_at

    assert_difference -> { alerts_for(c).count }, 1 do
      Contests::RevealSweepJob.perform_now
    end
  end

  test "the sweep is scheduled as an ActiveJob" do
    entry = YAML.load_file(Rails.root.join("config/schedule.yml")).fetch("contest_reveal_sweep")

    assert_equal "Contests::RevealSweepJob", entry["class"]
    assert_equal true, entry["active_job"]
  end
end
