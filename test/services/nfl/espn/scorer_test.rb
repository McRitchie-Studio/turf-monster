require "test_helper"

# [unit] Nfl::Espn::Scorer — who scored, from ESPN's play text.
#
# Every line below is REAL text captured from ESPN's summary endpoint (23 games,
# Sept-Oct 2025), not invented. That matters: the whole approach rests on a claim
# about a feed we do not control — that the scorer leads the sentence in every
# shape it produces — and a test written from imagination would only prove the
# regex matches the examples the regex was written for.
class Nfl::Espn::ScorerTest < ActiveSupport::TestCase
  # The four cases the product asks for, which turn out to be one rule.
  test "a passing touchdown credits the RECEIVER, not the passer" do
    assert_equal "Josh Oliver",
      Nfl::Espn::Scorer.from("Josh Oliver 12 Yd pass from Carson Wentz (Will Reichard Kick)")
    assert_equal "Michael Pittman Jr.",
      Nfl::Espn::Scorer.from("Michael Pittman Jr. 20 Yd pass from Daniel Jones (Spencer Shrader Kick)")
  end

  test "a rushing touchdown credits the RUSHER" do
    assert_equal "Jordan Mason", Nfl::Espn::Scorer.from("Jordan Mason 5 Yd Rush (Will Reichard Kick)")
    assert_equal "Jonathan Taylor", Nfl::Espn::Scorer.from("Jonathan Taylor 46 Yd Rush (Spencer Shrader Kick)")
  end

  test "a defensive touchdown credits the player who took it in" do
    assert_equal "Isaiah Rodgers",
      Nfl::Espn::Scorer.from("Isaiah Rodgers 87 Yd Interception Return (Will Reichard Kick)")
    assert_equal "Isaiah Rodgers",
      Nfl::Espn::Scorer.from("Isaiah Rodgers 66 Yd Fumble Recovery (Will Reichard Kick)")
    assert_equal "Kenny Moore II",
      Nfl::Espn::Scorer.from("Kenny Moore II 32 Yd Interception Return (Spencer Shrader Kick)")
  end

  test "a field goal credits the KICKER" do
    assert_equal "Will Reichard", Nfl::Espn::Scorer.from("Will Reichard 35 Yd Field Goal")
    assert_equal "Brandon McManus", Nfl::Espn::Scorer.from("Brandon McManus 39 Yd Field Goal")
  end

  # THE TRAP THIS AVOIDS. Every touchdown line ends with the extra point in
  # parentheses — a different player, a different event, folded into the same
  # row by the feed. Reading it would credit the kicker with every touchdown in
  # the league.
  test "the parenthetical kicker is never the scorer" do
    text = "Drew Sample 4 Yd pass from Jake Browning (Evan McPherson Kick)"
    assert_equal "Drew Sample", Nfl::Espn::Scorer.from(text)
    assert_not_equal "Evan McPherson", Nfl::Espn::Scorer.from(text)
  end

  test "names carrying punctuation survive intact" do
    assert_equal "T.J. Hockenson",
      Nfl::Espn::Scorer.from("T.J. Hockenson 5 Yd pass from Carson Wentz (Will Reichard Kick)")
    assert_equal "Ja'Marr Chase",
      Nfl::Espn::Scorer.from("Ja'Marr Chase 12 Yd pass from Joe Burrow (Evan McPherson Kick)")
    assert_equal "Harold Fannin Jr.",
      Nfl::Espn::Scorer.from("Harold Fannin Jr. 1 Yd pass from Dillon Gabriel (Andre Szmyt Kick)")
    assert_equal "JuJu Smith-Schuster",
      Nfl::Espn::Scorer.from("JuJu Smith-Schuster 8 Yd pass from Aaron Rodgers (Chris Boswell Kick)")
  end

  # The shapes that carry no yardage. All four of these are real lines that the
  # first version of the pattern missed.
  test "the yardage-less lines still name their scorer" do
    assert_equal "Kaevon Merriweather", Nfl::Espn::Scorer.from("Kaevon Merriweather Safety")
    assert_equal "Markquese Bell", Nfl::Espn::Scorer.from("Markquese Bell Defensive PAT Conversion")
    assert_equal "Sydney Brown",
      Nfl::Espn::Scorer.from("Sydney Brown 35 yd. return of blocked punt (J.Elliott kick)")
  end

  test "a lowercase yard abbreviation is the same play" do
    assert_equal "Sydney Brown", Nfl::Espn::Scorer.from("Sydney Brown 35 yd. return of blocked punt")
  end

  # A single leading word is a team, not a person. Crediting "Bengals" as the
  # scorer would put a team name where a player's name goes and send the
  # headshot lookup after a person who does not exist.
  test "a one-word subject is not a scorer" do
    assert_nil Nfl::Espn::Scorer.from("Bengals Safety")
    assert_nil Nfl::Espn::Scorer.from("Vikings 2 Yd Rush")
  end

  test "nothing to parse yields nothing" do
    assert_nil Nfl::Espn::Scorer.from(nil)
    assert_nil Nfl::Espn::Scorer.from("")
    assert_nil Nfl::Espn::Scorer.from("   ")
    assert_nil Nfl::Espn::Scorer.from("End of Quarter")
  end

  # The lazy quantifier has to stop AT the play, not run through it. If it ever
  # gets greedy this is the test that says so.
  test "the name never swallows the play itself" do
    %w[pass Rush Return Kick Field].each do |verb|
      name = Nfl::Espn::Scorer.from("Jordan Mason 5 Yd #{verb} (Will Reichard Kick)")
      assert_equal "Jordan Mason", name, "#{verb} leaked into the name"
    end
  end
end
