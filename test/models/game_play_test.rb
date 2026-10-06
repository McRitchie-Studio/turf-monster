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

  # ── the play summary: what, how far, who ─────────────────────────────────
  #
  # Every text below is a line ESPN served for DET at CAR on 2026-10-04.

  REAL = {
    completion: ["Pass Reception", "(Shotgun) J.Goff pass short left to J.Williams to DET 48 for 6 yards (A.Evans).", 6],
    incomplete: ["Pass Incompletion", "(Shotgun) J.Goff pass incomplete short left to I.TeSlaa (B.Okereke).", 0],
    rush:       ["Rush", "J.Gibbs up the middle to DET 42 for 7 yards (P.Jones).", 7],
    loss:       ["Rush", "C.Hubbard up the middle to ARI 26 for -4 yards (A.McNeill).", -4],
    sack:       ["Sack", "(Shotgun) B.Young sacked at CAR 45 for -10 yards (A.McNeill).", -10],
    pass_td:    ["Passing Touchdown", "(Shotgun) B.Young pass deep right to T.McMillan for 32 yards, TOUCHDOWN [D.Wonnum]. R.Fitzgerald extra point is No Good, Hit Right Upright, Center-J.Jansen, Holder-S.Martin.", 32],
    rush_td:    ["Rushing Touchdown", "C.Hubbard left tackle for 15 yards, TOUCHDOWN. R.Fitzgerald extra point is GOOD, Center-J.Jansen, Holder-S.Martin.", 15],
    field_goal: ["Field Goal Good", "J.Bates 54 yard field goal is GOOD, Center-H.Hatten, Holder-J.Fox.", nil],
    punt:       ["Punt", "S.Martin punts 44 yards to DET 11, Center-J.Jansen, fair catch by T.Kennedy.", nil],
    kickoff:    ["Kickoff", "R.Fitzgerald kicks 65 yards from CAR 35 to end zone, Touchback to the DET 35.", nil],
    penalty:    ["Penalty", "PENALTY on DET-B.Wright, False Start, 5 yards, enforced at CAR 34 - No Play.", nil],
    timeout:    ["Timeout", "Timeout #1 by DET at 12:09.", nil],
    warning:    ["Two-minute warning", "Two-Minute Warning", nil]
  }.freeze

  def real(key, **extra)
    type, text, yards = REAL.fetch(key)
    GamePlay.new(play_type: type, text: text, yards: yards, kind: "play", **extra)
  end

  test "the summary drops the formation, the coverage, the tacklers and the aftermath" do
    assert_equal "J.Goff pass short left to J.Williams to DET 48 for 6 yards.", real(:completion).summary
    assert_equal "B.Young pass deep right to T.McMillan for 32 yards, TOUCHDOWN.", real(:pass_td).summary
    assert_equal "J.Bates 54 yard field goal is GOOD.", real(:field_goal).summary
    assert_equal "Two-Minute Warning.", real(:warning).summary
    assert_equal "A.St. Brown left end for 4 yards.",
                 GamePlay.new(text: "(10:39) (Shotgun) A.St. Brown left end for 4 yards (D.Lloyd; Z.Wheatley).").summary
  end

  test "names the play the way a fan would" do
    expected = {
      completion: "Completion", incomplete: "Incompletion", rush: "Rush", sack: "Sack",
      pass_td: "Touchdown", rush_td: "Touchdown", field_goal: "Field Goal", punt: "Punt",
      kickoff: "Kickoff", penalty: "Penalty", timeout: "Timeout", warning: "Two-Minute Warning"
    }

    assert_equal expected, expected.keys.index_with { |key| real(key).result_label }
  end

  test "names the results the captured game did not contain" do
    {
      "Pass Interception Return"  => "Interception",
      "Fumble Recovery (Opponent)" => "Fumble Recovered",
      "Fumble Recovery (Own)"     => "Fumble",
      "Field Goal Missed"         => "Missed Field Goal",
      "Blocked Field Goal"        => "Blocked Field Goal",
      "Safety"                    => "Safety",
      "Official Timeout"          => "Official Timeout"
    }.each do |type, result|
      assert_equal result, GamePlay.new(play_type: type, text: "x").result_label
    end
  end

  # A scoreboard-sourced play can arrive with a type we have not listed. The
  # text is asked next, and the kind's own label is the last resort.
  test "an unlisted type falls back to the text, then to the kind" do
    assert_equal "Interception", GamePlay.new(play_type: "Something New", text: "pass INTERCEPTED by B.Baker").result_label
    assert_equal "Flag", GamePlay.new(play_type: nil, text: "x", kind: "penalty").result_label
    assert_equal "Something New", GamePlay.new(play_type: "Something New", text: "x", kind: "play").result_label
  end

  test "says how far, or what for, under the result" do
    expected = {
      completion: "6 yard pass", incomplete: "short left", rush: "7 yard rush", loss: "-4 yard rush",
      sack: "-10 yard sack", pass_td: "32 yard pass", rush_td: "15 yard rush", field_goal: "54 yards",
      punt: "44 yard punt", kickoff: "65 yard kick", penalty: "False Start, 5 yards", timeout: "by DET",
      warning: nil
    }

    assert_equal expected, expected.keys.index_with { |key| real(key).detail_label }
    assert_equal "no gain", GamePlay.new(play_type: "Rush", text: "x", yards: 0).detail_label
    assert_nil GamePlay.new(play_type: "Rush", text: "x").detail_label
  end

  # The feed names the passer first; a fan looks at the catch.
  test "puts the target ahead of the passer, and the feed's order everywhere else" do
    assert_equal %w[J.Williams J.Goff], real(:completion).players
    assert_equal %w[I.TeSlaa J.Goff], real(:incomplete).players
    assert_equal %w[T.McMillan B.Young], real(:pass_td).players, "the kicker of the extra point is aftermath"
    assert_equal %w[J.Gibbs], real(:rush).players, "the tackler is not who the play is about"
    assert_equal %w[J.Bates], real(:field_goal).players, "nor the snapper or the holder"
    assert_equal %w[B.Wright], real(:penalty).players
    assert_empty real(:timeout).players
  end

  test "the defender who took the ball leads an interception, and three is the most" do
    pick = GamePlay.new(play_type: "Pass Interception Return",
                        text: "(Shotgun) J.Goff pass short middle intended for S.LaPorta INTERCEPTED by B.Baker at ARI 30. B.Baker to ARI 35 for 5 yards.")

    assert_equal %w[B.Baker J.Goff S.LaPorta], pick.players
    crowd = GamePlay.new(text: "A.One pass to B.Two, lateral to C.Three, lateral to D.Four for 9 yards.")
    assert_equal 3, crowd.players.length
  end

  # An initial and a surname is only a name inside a roster — and the roster
  # is the two teams in this game, with the play's own team winning a tie.
  test "resolves names to athletes among the two teams in the game, in the same order" do
    game = games(:past_game) # team-a (home) vs team-b
    athlete = lambda do |first, last, team, tag|
      person = Person.create!(first_name: first, last_name: last, disambiguator: tag)
      Athlete.create!(person_slug: person.slug, sport: "football", team_slug: team)
    end
    goff      = athlete.("Jared", "Goff", "team-a", "a")
    other     = athlete.("Jim", "Goff", "team-b", "b")
    stranger  = athlete.("Jameson", "Williams", "team-c", "c")
    play = GamePlay.new(game: game, team_slug: "team-a", play_type: "Pass Reception",
                        text: "(Shotgun) J.Goff pass short left to J.Williams to DET 48 for 6 yards (A.Evans).")

    assert_equal %w[J.Williams J.Goff], play.players
    assert_equal [nil, goff], play.athletes, "a player on neither team is not ours to picture"
    assert_not_includes play.athletes, other
    assert_not_includes play.athletes, stranger

    defence = GamePlay.new(game: game, team_slug: "team-b", text: "J.Goff up the middle for 2 yards.")
    assert_equal [other], defence.athletes, "the play's own team wins a tie"
    assert_empty GamePlay.new(game: game, team_slug: "team-a", text: "Two-Minute Warning").athletes
  end

  # ── waiting for the kickoff ──────────────────────────────────────────────

  def feed(*specs) = specs.map { |type, kind| GamePlay.new(play_type: type, kind: kind, text: "x") }

  test "after a score, the TV timeout is looked past and the score is what the kickoff follows" do
    plays = feed(["Official Timeout", "break"], ["Rushing Touchdown", "score"], ["Rush", "play"])
    assert_equal "Touchdown", GamePlay.awaiting_kickoff_after(plays).result_label

    plays = feed(["Timeout", "timeout"], ["Field Goal Good", "score"])
    assert_equal "Field Goal", GamePlay.awaiting_kickoff_after(plays).result_label
  end

  test "the kickoff itself, any ordinary play, halftime or the end of the game ends the wait" do
    assert_nil GamePlay.awaiting_kickoff_after(feed(["Kickoff", "kick"], ["Passing Touchdown", "score"]))
    assert_nil GamePlay.awaiting_kickoff_after(feed(["Official Timeout", "break"], ["Rush", "play"]))
    assert_nil GamePlay.awaiting_kickoff_after(feed(["End of Half", "break"], ["Field Goal Good", "score"]))
    assert_nil GamePlay.awaiting_kickoff_after(feed(["Field Goal Missed", "kick"]))
    assert_nil GamePlay.awaiting_kickoff_after([])
  end

  test "the scorer kicks off, except after a safety" do
    game = Game.new(home_team_slug: "team-a", away_team_slug: "team-b")
    td = GamePlay.new(play_type: "Rushing Touchdown", text: "x")
    safety = GamePlay.new(play_type: "Safety", text: "x")

    assert_equal "team-a", GamePlay.kicking_team_slug(td, scorer_slug: "team-a", game: game)
    assert_equal "team-b", GamePlay.kicking_team_slug(safety, scorer_slug: "team-a", game: game)
  end

  # ── the review's follow-ups ──────────────────────────────────────────────

  test "while the score is the newest play, the bar shows the score itself" do
    assert_nil GamePlay.awaiting_kickoff_after(feed(["Rushing Touchdown", "score"], ["Rush", "play"]))
  end

  test "a missed or made try is looked past: the kickoff is still to come" do
    plays = feed(["Extra Point Missed", "kick"], ["Passing Touchdown", "score"])
    assert_equal "Extra Point", plays.first.result_label
    assert_equal "Touchdown", GamePlay.awaiting_kickoff_after(plays).result_label

    plays = feed(["Official Timeout", "break"], ["Two-Point Conversion Failed", "play"], ["Passing Touchdown", "score"])
    assert_equal "Touchdown", GamePlay.awaiting_kickoff_after(plays).result_label
  end

  test "a finished game has no kickoff coming, however it ended" do
    walk_off = feed(["Official Timeout", "break"], ["Field Goal Good", "score"])

    assert_nil GamePlay.awaiting_kickoff_after(walk_off, game: Game.new(status: "completed"))
    assert_not_nil GamePlay.awaiting_kickoff_after(walk_off, game: Game.new(status: "in_progress"))
  end

  # The play belongs to the offence that threw it; the points to the side that
  # took it back. Only the running score says which, and it needs no goal.
  test "the scorer is read off the running score, so a pick-six credits the defence" do
    game = Game.new(home_team_slug: "team-a", away_team_slug: "team-b")
    before = GamePlay.new(play_type: "Rush", kind: "play", text: "x", home_score: 7, away_score: 3, team_slug: "team-a")
    pick_six = GamePlay.new(play_type: "Interception Return Touchdown", kind: "score", text: "x",
                            home_score: 7, away_score: 9, team_slug: "team-a")
    timeout = GamePlay.new(play_type: "Official Timeout", kind: "break", text: "x")
    plays = [timeout, pick_six, before]

    assert_equal pick_six, GamePlay.awaiting_kickoff_after(plays, game: game)
    assert_equal "team-b", GamePlay.scoring_team_slug(pick_six, plays: plays, game: game)
  end

  test "with no running score to read, the scorer is left to the caller" do
    game = Game.new(home_team_slug: "team-a", away_team_slug: "team-b")
    score = GamePlay.new(play_type: "Rushing Touchdown", kind: "score", text: "x")

    assert_nil GamePlay.scoring_team_slug(score, plays: [score], game: game)
  end
end
