require "test_helper"

# Contest::LockRule — when entries close if nobody set a lock by hand. Pure
# function, no rows: the dates are the real 2026 NFL calendar (Week 4 opens on
# TNF, Thursday 2026-10-01 18:15 MDT = 2026-10-02 00:15Z; DST ends Sunday
# 2026-11-01).
class Contest::LockRuleTest < ActiveSupport::TestCase
  def utc(str) = Time.utc(*str.split(/[-T:]/).map(&:to_i))

  def nfl(first, last = nil)
    Contest::LockRule.default_lock_at(sport: "nfl", first_kickoff: first, last_kickoff: last)
  end

  test "a TNF week locks at 11:00 Denver on its Sunday, not at Thursday's kickoff" do
    lock = nfl(utc("2026-10-02T00:15"), utc("2026-10-06T00:15"))

    assert_equal utc("2026-10-04T17:00"), lock, "Sunday 2026-10-04 11:00 MDT"
    assert_equal "America/Denver", lock.time_zone.name
  end

  test "a Sunday-only slate opening at 1 PM ET locks at that kickoff" do
    assert_equal utc("2026-10-04T17:00"), nfl(utc("2026-10-04T17:00"), utc("2026-10-05T00:20"))
  end

  test "a London game Sunday morning does not pull the lock earlier" do
    # 9:30 ET London kickoff is before 11:00 Denver; that team freezes on its own
    # (SlateMatchup#pick_locked?), the contest still locks at 11:00.
    assert_equal utc("2026-10-04T17:00"), nfl(utc("2026-10-04T13:30"), utc("2026-10-05T00:20"))
  end

  test "a Sunday-night-only slate locks at its own kickoff, never before it" do
    # 18:20 MDT Sunday is 00:20Z MONDAY: read in UTC the opening Sunday would be
    # a week later. The Denver zone is what keeps it on the same day.
    snf = utc("2026-10-05T00:20")

    assert_equal snf, nfl(snf, snf)
  end

  test "a span slate (Weeks 4-6) locks on the first week's Sunday" do
    assert_equal utc("2026-10-04T17:00"), nfl(utc("2026-10-02T00:15"), utc("2026-10-20T00:15"))
  end

  test "across the DST change the lock stays 11:00 Denver (1 PM ET)" do
    # Week 9: TNF Thursday 2026-10-29 (MDT), Sunday 2026-11-01 is already MST.
    assert_equal utc("2026-11-01T18:00"), nfl(utc("2026-10-30T00:15"), utc("2026-11-03T01:15"))
    # And the week before, still on MDT.
    assert_equal utc("2026-10-25T17:00"), nfl(utc("2026-10-23T00:15"), utc("2026-10-27T00:15"))
  end

  test "a slate whose games all fall before Sunday locks at its last kickoff, not after every game" do
    thursday = utc("2026-10-02T00:15")
    saturday = utc("2026-10-03T20:00")

    assert_equal thursday, nfl(thursday, thursday), "Thursday-only"
    assert_equal saturday, nfl(thursday, saturday), "Thursday + Saturday"
  end

  test "a Saturday-night game whose UTC date is Sunday still locks Sunday 11:00" do
    # 18:15 MST Saturday 2026-12-19 = 01:15Z Sunday 2026-12-20.
    assert_equal utc("2026-12-20T18:00"), nfl(utc("2026-12-20T01:15"), utc("2026-12-21T01:15"))
  end

  test "an NFL slate with no game times falls back to the slate start and still applies the rule" do
    lock = Contest::LockRule.default_lock_at(sport: "nfl", first_kickoff: nil, fallback: utc("2026-10-02T00:15"))

    assert_equal utc("2026-10-04T17:00"), lock
  end

  test "a non-NFL slate keeps today's rule: the first kickoff, else the slate start" do
    first = utc("2026-06-11T19:00")

    assert_equal first, Contest::LockRule.default_lock_at(sport: "fifa", first_kickoff: first, last_kickoff: utc("2026-06-20T19:00"))
    assert_equal first, Contest::LockRule.default_lock_at(sport: "fifa", first_kickoff: nil, fallback: first)
    assert_nil Contest::LockRule.default_lock_at(sport: "fifa", first_kickoff: nil)
    assert_nil Contest::LockRule.default_lock_at(sport: "nfl", first_kickoff: nil)
  end
end
