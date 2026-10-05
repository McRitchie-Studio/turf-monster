require "test_helper"

# [unit] Which of a span contest's games the live board shows. Pure: the module
# reads `kickoff_at` off whatever it is handed and touches no database.
class Contest::WeekWindowTest < ActiveSupport::TestCase
  Stub = Struct.new(:name, :kickoff_at)

  DENVER = ActiveSupport::TimeZone["America/Denver"]

  # Week 4 of 2026: Tuesday 9/29 07:00 Denver to Tuesday 10/6 07:00 Denver.
  def at(*args) = DENVER.local(*args)

  def game(name, *args) = Stub.new(name, args.empty? ? nil : at(*args))

  test "the week starts on Tuesday at 7 AM Denver" do
    start = Contest::WeekWindow.start_for(at(2026, 10, 4, 21, 18))

    assert_equal at(2026, 9, 29, 7, 0), start
    assert_equal 2, start.wday
  end

  test "Tuesday before 7 AM still belongs to the week that is ending" do
    assert_equal at(2026, 9, 29, 7, 0), Contest::WeekWindow.start_for(at(2026, 10, 6, 6, 59))
    assert_equal at(2026, 10, 6, 7, 0), Contest::WeekWindow.start_for(at(2026, 10, 6, 7, 0))
  end

  test "the turn stays at 7 on the wall clock across the DST change" do
    # Clocks fall back on Sunday 2026-11-01. A fixed offset would land at 6 AM.
    start = Contest::WeekWindow.start_for(at(2026, 11, 5, 12, 0))

    assert_equal at(2026, 11, 3, 7, 0), start
    assert_equal 7, start.hour
  end

  test "a game on the DST Sunday itself is in the same week as its Thursday" do
    # A 23- or 25-hour day: midnight plus seven hours is 6 AM (or 8), not 7.
    fall, spring = at(2026, 10, 27, 7, 0), at(2026, 3, 3, 7, 0)

    assert_equal fall,   Contest::WeekWindow.start_for(at(2026, 11, 1, 11, 0))
    assert_equal fall,   Contest::WeekWindow.start_for(at(2026, 10, 29, 18, 15))
    assert_equal spring, Contest::WeekWindow.start_for(at(2026, 3, 8, 12, 0))
  end

  test "a UTC instant is read in Denver, not on its own calendar day" do
    # Tuesday 10/6 02:15 UTC is Monday Night Football, 8:15 PM Denver on 10/5.
    monday_night = Time.utc(2026, 10, 6, 2, 15)

    assert_equal at(2026, 9, 29, 7, 0), Contest::WeekWindow.start_for(monday_night)
  end

  test "shows only the current week of a multi-week contest" do
    thursday = game("thu", 2026, 10, 1, 18, 15)
    sunday   = game("sun", 2026, 10, 4, 18, 20)
    monday   = game("mon", 2026, 10, 5, 18, 15)
    next_sun = game("next", 2026, 10, 11, 14, 25)
    last_sun = game("last", 2026, 9, 27, 14, 25)

    shown = Contest::WeekWindow.current([last_sun, thursday, sunday, monday, next_sun], at(2026, 10, 4, 21, 18))

    assert_equal %w[thu sun mon], shown.map(&:name)
  end

  test "the board turns over to next week on Tuesday morning" do
    monday   = game("mon", 2026, 10, 5, 18, 15)
    next_sun = game("next", 2026, 10, 11, 14, 25)

    assert_equal %w[mon],  Contest::WeekWindow.current([monday, next_sun], at(2026, 10, 6, 6, 59)).map(&:name)
    assert_equal %w[next], Contest::WeekWindow.current([monday, next_sun], at(2026, 10, 6, 7, 0)).map(&:name)
  end

  test "an empty current week falls forward to the next week with games" do
    first = game("first", 2026, 10, 11, 14, 25)
    later = game("later", 2026, 10, 18, 14, 25)

    assert_equal %w[first], Contest::WeekWindow.current([later, first], at(2026, 10, 4, 12, 0)).map(&:name)
  end

  test "after the last week it keeps showing the last week, never nothing" do
    early = game("early", 2026, 9, 27, 14, 25)
    final = game("final", 2026, 10, 4, 18, 20)

    assert_equal %w[final], Contest::WeekWindow.current([early, final], at(2026, 11, 1, 12, 0)).map(&:name)
  end

  test "a game with no kickoff rides along with the week that is showing" do
    sunday  = game("sun", 2026, 10, 4, 18, 20)
    untimed = game("tbd")
    other   = game("next", 2026, 10, 11, 14, 25)

    assert_equal %w[sun tbd], Contest::WeekWindow.current([untimed, sunday, other], at(2026, 10, 4, 12, 0)).map(&:name)
  end

  test "games with no kickoffs at all are returned untouched" do
    games = [game("a"), game("b")]

    assert_equal games, Contest::WeekWindow.current(games, at(2026, 10, 4, 12, 0))
    assert_equal [], Contest::WeekWindow.current([], at(2026, 10, 4, 12, 0))
  end
end
