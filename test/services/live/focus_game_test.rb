require "test_helper"

# [unit] THE FOCUS LADDER — which game the live board opens on.
#
# The scenarios below are the operator's own walk through an NFL week, hour by
# hour, because that is the specification: "Tuesday to Thursday the focus is
# the upcoming Thursday night game… Sunday morning it shifts to the highest
# ranked morning game… after Sunday night football keep Sunday night football,
# but the next morning Monday night football." Each test names the moment it
# stands at, so a rule that gets quietly reversed later fails under the
# sentence it broke.
#
# No records are saved. The service reads three attributes off each game and
# nothing else, so unsaved instances are the whole subject — and a test that
# cannot touch the database cannot accidentally depend on one.
class Live::FocusGameTest < ActiveSupport::TestCase
  # One real week, in UTC. The Eastern kickoff each line is written from is in
  # the comment, because "Fri 00:15 UTC" is Thursday night football and nobody
  # reading a bare timestamp would know that.
  TNF        = Time.utc(2026, 9, 11, 0, 15)   # Thu 8:15pm ET
  SUN_EARLY  = Time.utc(2026, 9, 13, 17, 0)   # Sun 1:00pm ET
  SUN_EARLY2 = Time.utc(2026, 9, 13, 17, 5)   # Sun 1:05pm ET — same wave
  SUN_LATE   = Time.utc(2026, 9, 13, 20, 25)  # Sun 4:25pm ET — a different one
  SNF        = Time.utc(2026, 9, 14, 0, 20)   # Sun 8:20pm ET
  MNF        = Time.utc(2026, 9, 15, 0, 15)   # Mon 8:15pm ET

  def game(slug, status: "scheduled", kickoff: nil, rank: nil)
    Game.new(slug: slug, status: status, kickoff_at: kickoff, focus_rank: rank)
  end

  # ── RUNG 1 · LIVE ────────────────────────────────────────────────────────

  test "among games being played the best rank leads" do
    early = game("early", status: "in_progress", kickoff: SUN_EARLY, rank: 3)
    late  = game("late",  status: "in_progress", kickoff: SUN_EARLY2, rank: 1)

    assert_equal late, Live::FocusGame.pick([early, late], now: SUN_EARLY + 30.minutes)
  end

  # The operator's rule in full: "highest ranked, it has to have not finished,
  # and must have been started." A rank-1 night game must not own the board
  # while the afternoon is being played, and this is the test that says so.
  test "a rank-1 game that has not kicked off does not take the board from a live game" do
    playing = game("playing", status: "in_progress", kickoff: SUN_EARLY, rank: 4)
    tonight = game("tonight", kickoff: SNF, rank: 1)

    assert_equal playing, Live::FocusGame.pick([playing, tonight], now: SUN_EARLY + 1.hour)
  end

  # The poller flips `status` on its own cycle, so for a minute after kickoff a
  # game being played still reads "scheduled". A board that answers "nothing is
  # on" while the ball is in the air is wrong in the one minute it most matters.
  test "a passed kickoff counts as started even before the poller says so" do
    kicked_off = game("kicked-off", status: "scheduled", kickoff: SUN_EARLY, rank: 2)
    tonight    = game("tonight", kickoff: SNF, rank: 1)

    assert_equal kicked_off, Live::FocusGame.pick([kicked_off, tonight], now: SUN_EARLY + 1.minute)
  end

  test "a finished game never leads while another is being played" do
    done    = game("done", status: "completed", kickoff: SUN_EARLY, rank: 1)
    playing = game("playing", status: "in_progress", kickoff: SUN_LATE, rank: 4)

    assert_equal playing, Live::FocusGame.pick([done, playing], now: SUN_LATE + 30.minutes)
  end

  # "When that game ends the focus should transition to the next highest rank."
  test "when the best-ranked game finishes the next-best live game takes over" do
    finished = game("finished", status: "completed", kickoff: SUN_EARLY, rank: 1)
    second   = game("second",   status: "in_progress", kickoff: SUN_EARLY2, rank: 2)
    third    = game("third",    status: "in_progress", kickoff: SUN_EARLY2, rank: 3)

    assert_equal second, Live::FocusGame.pick([finished, second, third], now: SUN_LATE)
  end

  # ── RUNG 2 · IMMINENT ────────────────────────────────────────────────────

  # Sunday breakfast. Nothing is live, and the highest-ranked game of the week
  # is usually the night one — so without the wave the board would lead with an
  # 8:20pm kickoff from 8am and hold it right through the afternoon.
  test "on Sunday morning the wave keeps the night game off the board" do
    early_a = game("early-a", kickoff: SUN_EARLY,  rank: 3)
    early_b = game("early-b", kickoff: SUN_EARLY2, rank: 2)
    night   = game("night",   kickoff: SNF,        rank: 1)

    focus = Live::FocusGame.pick([early_a, early_b, night], now: SUN_EARLY - 4.hours)
    assert_equal early_b, focus, "the best-ranked game in the FIRST wave should lead"
  end

  test "the wave reaches the 1:05 kickoffs and stops short of the afternoon" do
    # The afternoon game is deliberately the BEST-ranked of the three: if the
    # wave were not doing anything, rank alone would hand it the board at
    # eleven in the morning.
    early = game("early", kickoff: SUN_EARLY,  rank: 3)
    also  = game("also",  kickoff: SUN_EARLY2, rank: 2)
    late  = game("late",  kickoff: SUN_LATE,   rank: 1)

    focus = Live::FocusGame.pick([early, also, late], now: SUN_EARLY - 2.hours)
    assert_equal also, focus, "1:00 and 1:05 are one wave; the 4:25 game is not in it"
  end

  # "The next morning Monday night football should be the focus." Twelve hours
  # before an 8:15pm kickoff is 8:15 that morning.
  test "the next game takes the board on the morning of its kickoff" do
    finished = game("snf", status: "completed", kickoff: SNF, rank: 1)
    monday   = game("mnf", kickoff: MNF, rank: 2)

    assert_equal monday, Live::FocusGame.pick([finished, monday], now: MNF - 11.hours)
  end

  # ── RUNG 3 · HOLDOVER ────────────────────────────────────────────────────

  # "When there is no other game going the focus shouldn't shift — after Sunday
  # night football keep Sunday night football."
  test "after the last game of the night the finished game holds the board" do
    finished = game("snf", status: "completed", kickoff: SNF, rank: 1)
    monday   = game("mnf", kickoff: MNF, rank: 2)

    assert_equal finished, Live::FocusGame.pick([finished, monday], now: SNF + 3.hours)
  end

  test "the holdover is the game that finished last, not the best-ranked one" do
    marquee = game("marquee", status: "completed", kickoff: SUN_EARLY, rank: 1)
    night   = game("night",   status: "completed", kickoff: SNF,       rank: 4)

    assert_equal night, Live::FocusGame.pick([marquee, night], now: SNF + 3.hours)
  end

  # ── RUNG 4 · FALLBACK ────────────────────────────────────────────────────

  # "Tuesday to Thursday the focus is the upcoming Thursday night game." By
  # Tuesday the board has rolled onto a week nothing has been played in yet, so
  # there is no holdover to keep and the soonest kickoff is the answer — even
  # though it is two days out and no rank was ever set.
  test "with nothing played and nothing imminent the soonest kickoff leads" do
    thursday = game("tnf", kickoff: TNF)
    sunday   = game("sun", kickoff: SUN_EARLY, rank: 1)

    assert_equal thursday, Live::FocusGame.pick([thursday, sunday], now: TNF - 2.days)
  end

  test "an unranked field falls back to kickoff order" do
    first  = game("first",  kickoff: SUN_EARLY)
    second = game("second", kickoff: SUN_LATE)

    assert_equal first, Live::FocusGame.pick([second, first], now: SUN_EARLY - 2.days)
  end

  # ── EDGES AND POLICY ─────────────────────────────────────────────────────

  test "an empty set has no focus" do
    assert_nil Live::FocusGame.pick([])
    assert_nil Live::FocusGame.call([])
  end

  test "call answers with the slug the views need" do
    playing = game("the-game", status: "in_progress", kickoff: SUN_EARLY)

    assert_equal "the-game", Live::FocusGame.call([playing], now: SUN_EARLY + 1.hour)
  end

  # A game with no kickoff is not "soon" and is not "what just ended" — it
  # sorts last among the upcoming and first among the finished.
  test "a game with no kickoff time never wins on recency" do
    undated  = game("undated", status: "completed")
    finished = game("finished", status: "completed", kickoff: SUN_EARLY)

    assert_equal finished, Live::FocusGame.pick([undated, finished], now: SNF)
  end

  # The policy is READ, not decoration: soccer's six-hour lead-in leaves a game
  # on the board that the NFL's twelve would already have handed over.
  test "the policy's lead-in decides when the next game takes over" do
    finished = game("finished", status: "completed", kickoff: SNF)
    upcoming = game("upcoming", kickoff: MNF)
    eight_hours_before = MNF - 8.hours

    assert_equal upcoming, Live::FocusGame.pick([finished, upcoming], now: eight_hours_before),
                 "the NFL's 12h lead-in has opened"
    assert_equal finished, Live::FocusGame.pick([finished, upcoming], policy: :soccer, now: eight_hours_before),
                 "soccer's 6h lead-in has not"
  end

  test "an unknown policy raises rather than quietly using another sport's numbers" do
    error = assert_raises(ArgumentError) do
      Live::FocusGame.pick([game("g", kickoff: MNF)], policy: :curling)
    end
    assert_match(/curling/, error.message)
  end
end
