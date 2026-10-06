# frozen_string_literal: true

require "test_helper"

# [unit] The /turf-monster-v2 CTA's one decision: link to the next NFL contest a
# visitor can still enter, or open the notify-me modal. A locked contest is
# never chosen (EntryGift#landing_contest's Contest.featured fallback checks no
# lock; this must not repeat that).
class NextContestTest < ActiveSupport::TestCase
  setup do
    SeasonConfig.set_main_contest!(nil)
    Selection.delete_all
    Entry.delete_all
    Contest.delete_all
    @nfl = Slate.create!(name: "NFL 2026 Weeks 7-9", slug: "nfl-2026-weeks-7-9-test", sport: "nfl",
                         starts_at: 10.days.from_now)
  end

  def contest(slug, starts_at:, status: "open", coming_soon: false, slate: @nfl)
    Contest.create!(name: slug.titleize, slug: slug, status: status, coming_soon: coming_soon,
                    entry_fee_cents: 1900, max_entries: 29, contest_type: "standard",
                    slate: slate, starts_at: starts_at)
  end

  test "no contest at all opens the modal" do
    pick = NextContest.pick
    assert pick.modal?
    refute pick.link?
    assert_nil pick.contest
  end

  test "an open, unlocked contest is a link" do
    open = contest("weeks-7-9", starts_at: 3.days.from_now)
    pick = NextContest.pick
    assert pick.link?
    assert_equal open, pick.contest
  end

  test "a locked contest is never chosen, even when it is the only open one" do
    contest("weeks-5-7", starts_at: 1.hour.ago)
    assert NextContest.pick.modal?
  end

  test "the lock is read at the instant asked, to the second" do
    c = contest("weeks-7-9", starts_at: 2.days.from_now)
    assert_equal c, NextContest.pick(now: c.locks_at - 1.second).contest
    assert NextContest.pick(now: c.locks_at).modal?
  end

  test "the soonest lock wins among enterable contests" do
    contest("later", starts_at: 9.days.from_now)
    sooner = contest("sooner", starts_at: 2.days.from_now)
    contest("locked", starts_at: 1.day.ago)
    assert_equal sooner, NextContest.pick.contest
  end

  test "coming soon, cancelled, pending, settled and non-NFL contests are passed over" do
    contest("soon", starts_at: 2.days.from_now, coming_soon: true)
    contest("pending", starts_at: 2.days.from_now, status: "pending")
    contest("settled", starts_at: 2.days.from_now, status: "settled")
    contest("soccer", starts_at: 2.days.from_now, slate: slates(:one))
    contest("cancelled", starts_at: 2.days.from_now).update_column(:onchain_cancelled, true)

    assert NextContest.pick.modal?
  end

  test "the lobby holds enterable contests only, open before coming soon, capped" do
    contest("locked", starts_at: 1.hour.ago)
    soon = contest("soon", starts_at: 4.days.from_now, coming_soon: true)
    open = contest("open", starts_at: 3.days.from_now)
    lobby = NextContest.lobby
    assert_equal [open, soon], lobby.contests
    assert_equal({}, lobby.entry_counts)
    5.times { |i| contest("more-#{i}", starts_at: (i + 5).days.from_now) }
    assert_equal NextContest::LOBBY_LIMIT, NextContest.lobby.contests.size
  end

  test "the live showcase prefers a contest being played, then the latest finished, then nil" do
    assert_nil NextContest.live_showcase
    finished = contest("finished", starts_at: 20.days.ago, status: "settled")
    assert_equal finished, NextContest.live_showcase.contest
    playing = contest("playing", starts_at: 1.day.ago)
    showcase = NextContest.live_showcase
    assert_equal playing, showcase.contest
    assert showcase.live?
    contest("soccer-live", starts_at: 1.hour.ago, slate: slates(:one))
    assert_equal playing, NextContest.live_showcase.contest, "NFL only"
  end
end
