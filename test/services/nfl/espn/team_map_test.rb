require "test_helper"

# [unit] ESPN abbreviation -> Team.
#
# Diffing ESPN's 32 abbreviations against Nfl::TeamPalette's keys shows 31
# agreeing exactly, so this file exists almost entirely for the thirty-second.
class Nfl::Espn::TeamMapTest < ActiveSupport::TestCase
  # ESPN says WSH, we store WAS. Without the alias, Washington resolves to nil
  # on every play — a team that silently never scores, in a feed that settles
  # contests. That is the failure this test exists to prevent.
  test "WSH resolves to the team stored as WAS" do
    washington = Team.create!(
      name: "Washington Commanders", short_name: "WAS", slug: "washington-commanders",
      sport: "football", league: "nfl"
    )

    assert_equal washington, Nfl::Espn::TeamMap.team_for("WSH")
    assert_equal "WAS", Nfl::Espn::TeamMap.canonical("WSH")
  end

  test "every other abbreviation passes straight through" do
    assert_equal "SF", Nfl::Espn::TeamMap.canonical("SF")
    assert_equal teams(:team_a), Nfl::Espn::TeamMap.team_for("TMA")
  end

  test "an unknown or blank abbreviation resolves to nil rather than raising" do
    assert_nil Nfl::Espn::TeamMap.team_for("ZZZ")
    assert_nil Nfl::Espn::TeamMap.team_for("")
    assert_nil Nfl::Espn::TeamMap.team_for(nil)
  end

  # The scope matters: a non-NFL team sharing an abbreviation must never be
  # picked up by the NFL feed.
  test "only looks inside the NFL league" do
    Team.create!(name: "Soccer TMA", short_name: "TMA", slug: "soccer-tma",
                 sport: "soccer", league: "fifa")

    assert_equal teams(:team_a), Nfl::Espn::TeamMap.team_for("TMA")
  end
end
