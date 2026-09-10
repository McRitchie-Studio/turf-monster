require "test_helper"

# [unit] Nfl::Espn::PlayDescription — the "22 yard receiving TD" line.
#
# Every string below is REAL text from ESPN's summary endpoint. That matters
# more here than usual: the whole module is a bet about a feed we do not control,
# and it was measured against 235 live scoring plays before it was trusted.
class Nfl::Espn::PlayDescriptionTest < ActiveSupport::TestCase
  test "a pass credits the catch, in yards" do
    assert_equal "12 yard receiving TD",
      Nfl::Espn::PlayDescription.from("Josh Oliver 12 Yd pass from Carson Wentz (Will Reichard Kick)")
  end

  test "a rush credits the run, in yards" do
    assert_equal "5 yard rushing TD",
      Nfl::Espn::PlayDescription.from("Jordan Mason 5 Yd Rush (Will Reichard Kick)")
  end

  # ESPN WRITES BOTH "Rush" AND "Run" for the same play. Matching only "Rush"
  # silently dropped the description on 6 of 235 measured plays — every Josh
  # Jacobs score among them — and a dropped description is a blank line on the
  # card, not an error anyone would notice.
  test "Run is the same play as Rush" do
    assert_equal "18 yard rushing TD",
      Nfl::Espn::PlayDescription.from("Josh Jacobs 18 Yd Run (Brandon McManus Kick)")
    assert_equal "3 yard rushing TD",
      Nfl::Espn::PlayDescription.from("Jonathan Taylor 3 Yd Run (Spencer Shrader Kick)")
  end

  test "a field goal keeps its distance" do
    assert_equal "35 yard field goal",
      Nfl::Espn::PlayDescription.from("Will Reichard 35 Yd Field Goal")
    assert_equal "62 yard field goal",
      Nfl::Espn::PlayDescription.from("Will Reichard 62 Yd Field Goal")
  end

  # The defensive scores collapse ON PURPOSE. An interception return, a fumble
  # recovery and a blocked-punt return are three plays and one thing to a reader
  # glancing at a live card — and "87 yard interception return TD" is the longest
  # string this line can produce, in the narrowest space it has.
  test "every defensive score reads as one thing" do
    [
      "Isaiah Rodgers 87 Yd Interception Return (Will Reichard Kick)",
      "Isaiah Rodgers 66 Yd Fumble Recovery (Will Reichard Kick)",
      "Sydney Brown 35 yd. return of blocked punt (J.Elliott kick)"
    ].each do |text|
      assert_equal "Defensive touchdown", Nfl::Espn::PlayDescription.from(text), text
    end
  end

  test "a safety and a defensive conversion say so" do
    assert_equal "Safety", Nfl::Espn::PlayDescription.from("Kaevon Merriweather Safety")
    assert_equal "Defensive conversion",
      Nfl::Espn::PlayDescription.from("Markquese Bell Defensive PAT Conversion")
  end

  # A shape we have never seen still says something true when the caller knows
  # the scoring type — the card drops a blank line, never a wrong one.
  test "an unrecognised line falls back to the scoring type" do
    assert_equal "Touchdown", Nfl::Espn::PlayDescription.from("Something entirely new", "touchdown")
    assert_equal "Field goal", Nfl::Espn::PlayDescription.from("Something entirely new", "field_goal")
  end

  test "no text and no type yields nothing to print" do
    assert_nil Nfl::Espn::PlayDescription.from(nil)
    assert_nil Nfl::Espn::PlayDescription.from("")
    assert_nil Nfl::Espn::PlayDescription.from("Something entirely new")
  end
end
