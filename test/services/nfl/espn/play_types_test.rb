require "test_helper"

# [unit] The one table both the feed and the play-by-play bar classify plays
# from. Every row answers two questions; these pin the answers together.
class Nfl::Espn::PlayTypesTest < ActiveSupport::TestCase
  def classify(type) = Nfl::Espn::PlayTypes.classify(type)

  # Every type in the captured DET at CAR game, and what each reader makes of it.
  test "each real play type gets one kind and one result" do
    {
      "Kickoff"            => ["Kickoff", "kick"],
      "Rush"               => ["Rush", "play"],
      "Pass Reception"     => ["Completion", "play"],
      "Pass Incompletion"  => ["Incompletion", "play"],
      "Penalty"            => ["Penalty", "penalty"],
      "Timeout"            => ["Timeout", "timeout"],
      "Official Timeout"   => ["Official Timeout", "break"],
      "Field Goal Good"    => ["Field Goal", "score"],
      "Sack"               => ["Sack", "sack"],
      "Punt"               => ["Punt", "kick"],
      "Rushing Touchdown"  => ["Touchdown", "score"],
      "Passing Touchdown"  => ["Touchdown", "score"],
      "End Period"         => ["End of Quarter", "break"],
      "Two-minute warning" => ["Two-Minute Warning", "break"],
      "End of Half"        => ["Halftime", "break"]
    }.each do |type, (result, kind)|
      assert_equal [result, kind], [classify(type).result, classify(type).kind], type
    end
  end

  # ESPN writes the try with and without the hyphen. Both lists used to match
  # only the hyphen, so "Two Point Rush" was a Rush and ended a kickoff wait.
  test "every spelling of the two-point try is a try" do
    ["Two-Point Conversion", "Two Point Rush", "Two Point Pass", "Defensive Two-Point Conversion"].each do |type|
      assert_equal "Two-Point Try", classify(type).result, type
    end
    assert_equal "score", classify("Two Point Pass Good").kind
    assert_equal "play", classify("Two Point Rush").kind
  end

  test "the specific row beats the general one it contains" do
    assert_equal "Interception", classify("Pass Interception Return").result
    assert_equal "Touchdown", classify("Interception Return Touchdown").result
    assert_equal ["Missed Field Goal", "kick"], [classify("Field Goal Missed").result, classify("Field Goal Missed").kind]
    assert_equal ["Fumble Recovered", "turnover"], [classify("Fumble Recovery (Opponent)").result, classify("Fumble Recovery (Opponent)").kind]
    assert_equal ["Fumble", "play"], [classify("Fumble Recovery (Own)").result, classify("Fumble Recovery (Own)").kind]
    assert_equal "Extra Point", classify("Extra Point Good").result
  end

  test "a type nobody has seen matches nothing" do
    assert_nil classify("Something New In 2027")
    assert_nil classify("")
    assert_nil classify(nil)
  end

  # The feed's kinds and the board's vocabulary come from the same rows.
  test "the feed's kind vocabulary is exactly the table's" do
    assert_equal Nfl::Espn::PlayTypes::KINDS, Nfl::Espn::Plays::KINDS
    assert_equal Nfl::Espn::PlayTypes::KINDS, GamePlay::KINDS
  end
end
