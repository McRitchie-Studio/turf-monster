require "test_helper"

# [unit] GamePlay's two small computations: the order of a game's plays, and
# how a play's moment is written.
class GamePlayTest < ActiveSupport::TestCase
  # ESPN's play id is the event id with a counter on the end, and the counter
  # is not zero-padded — so the ids do NOT sort as strings ("...982" > "...4422").
  test "sequence is the play id with the game's event id taken off the front" do
    assert_equal 982,  GamePlay.sequence_for("401872978982", "401872978")
    assert_equal 4422, GamePlay.sequence_for("4018729784422", "401872978")
    assert_operator GamePlay.sequence_for("4018729784422", "401872978"), :>,
                    GamePlay.sequence_for("401872978982", "401872978")
  end

  test "an id that does not start with the event id keeps the whole number" do
    assert_equal 12345, GamePlay.sequence_for("12345", "401872978")
    assert_equal 77,    GamePlay.sequence_for("77", nil)
  end

  test "writes the quarter and clock the way the focus card does" do
    assert_equal "Q4 · 3:42", GamePlay.new(period: 4, clock: "3:42").clock_label
    assert_equal "OT · 9:10", GamePlay.new(period: 5, clock: "9:10").clock_label
    assert_equal "Q2",        GamePlay.new(period: 2).clock_label
    assert_nil GamePlay.new.clock_label
  end

  test "an ordinary snap has no label; a timeout does" do
    assert_nil GamePlay.new(kind: "play").label
    assert_equal "Timeout", GamePlay.new(kind: "timeout").label
    assert_equal "Flag",    GamePlay.new(kind: "penalty").label
  end

  test "a play id is stored once" do
    game = games(:past_game)
    GamePlay.create!(game_slug: game.slug, external_id: "X1", sequence: 1, text: "first")

    assert_raises(ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid) do
      GamePlay.create!(game_slug: game.slug, external_id: "X1", sequence: 2, text: "again")
    end
    assert_equal 1, game.plays.count
  end
end
