require "test_helper"

# [unit] The one constant the /turf-monster-v2 countdown reads. Alex set the
# drop as "Tuesday Oct 20, 2026, morning Mountain time"; the page uses 8:00 AM.
class NextSlateDropTest < ActiveSupport::TestCase
  test "the drop is 8:00 AM Mountain on Tuesday 2026-10-20, which is 14:00 UTC" do
    drops_at = NextSlateDrop::DROPS_AT

    assert_equal Time.utc(2026, 10, 20, 14, 0, 0), drops_at.utc
    assert drops_at.tuesday?, "the slate drops on a Tuesday"
    assert_equal 8, drops_at.in_time_zone("America/Denver").hour
    assert_equal(-6.hours.to_i, drops_at.utc_offset, "Mountain is on daylight time (MDT) on Oct 20")
  end

  test "the slate key and label name Weeks 7-9" do
    assert_equal "nfl-2026-weeks-7-9", NextSlateDrop::SLATE_KEY
    assert_equal "Weeks 7-9", NextSlateDrop::LABEL
  end

  # THE TRANSITION DAY ITSELF, and a day either side. Mountain falls back at
  # 2:00 AM on Sunday 2026-11-01 and springs forward at 2:00 AM on Sunday
  # 2026-03-08. Midnight + 8 hours lands at 7 AM on the first and 9 AM on the
  # second; change(hour:) lands at 8 on both.
  test "wall_clock lands on the named hour across the fall-back change" do
    { Date.new(2026, 10, 31) => 14, Date.new(2026, 11, 1) => 15, Date.new(2026, 11, 2) => 15 }.each do |date, utc_hour|
      t = NextSlateDrop.wall_clock(date, 8)
      assert_equal 8, t.hour, "#{date}: 8 o'clock on the Denver wall clock"
      assert_equal utc_hour, t.utc.hour, "#{date}: the right UTC instant"
    end
  end

  test "wall_clock lands on the named hour across the spring-forward change" do
    { Date.new(2026, 3, 7) => 15, Date.new(2026, 3, 8) => 14, Date.new(2026, 3, 9) => 14 }.each do |date, utc_hour|
      t = NextSlateDrop.wall_clock(date, 8)
      assert_equal 8, t.hour, "#{date}: 8 o'clock on the Denver wall clock"
      assert_equal utc_hour, t.utc.hour, "#{date}: the right UTC instant"
    end
  end

  test "dropped? flips at the instant, not before" do
    refute NextSlateDrop.dropped?(NextSlateDrop::DROPS_AT - 1.second)
    assert NextSlateDrop.dropped?(NextSlateDrop::DROPS_AT)
    assert NextSlateDrop.dropped?(NextSlateDrop::DROPS_AT + 1.day)
  end

  test "remaining splits the wait into whole days, hours and minutes, floored at zero" do
    now = NextSlateDrop::DROPS_AT - (2.days + 3.hours + 4.minutes + 59.seconds)
    assert_equal({ days: 2, hours: 3, minutes: 4 }, NextSlateDrop.remaining(now))
    assert_equal({ days: 0, hours: 0, minutes: 0 }, NextSlateDrop.remaining(NextSlateDrop::DROPS_AT + 1.hour))
  end
end
