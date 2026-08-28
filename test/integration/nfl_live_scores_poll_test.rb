require "test_helper"

# [integration] One polling cycle, across its whole I/O boundary: an ESPN
# payload in, Game + Goal rows and SlateMatchup propagation out.
#
# The HTTP client is stubbed — the point is the seam BELOW it. What the network
# actually returns is pinned by the unit tests over the parse seams.
class NflLiveScoresPollTest < ActionDispatch::IntegrationTest
  # Stands in for Nfl::Espn::Client. Records what was asked for, so a test can
  # assert that a summary was NOT fetched for a game whose score did not move —
  # the optimisation the whole polling budget rests on.
  class StubClient
    attr_reader :summary_calls

    def initialize(scoreboard:, summaries: {})
      @scoreboard = scoreboard
      @summaries = summaries
      @summary_calls = []
    end

    def scoreboard(**) = @scoreboard

    def summary(event_id:)
      @summary_calls << event_id
      # NOTE the default. It used to be {"scoringPlays" => []}, which is a
      # *reported* empty list — so no test could reach the DEGRADED path where
      # the key is absent entirely. That default is why the score-wipe shipped.
      @summaries.fetch(event_id, { "scoringPlays" => [] })
    end
  end

  # Only `team_a` carries league: nfl in the shared fixtures, and TeamMap looks
  # inside Team.nfl on purpose — so a non-NFL team sharing an abbreviation can
  # never be picked up by this feed. Enrolling the others here (inside the test
  # transaction) is cheaper than widening a fixture every other suite reads.
  setup do
    @home = teams(:team_a)
    @away = teams(:team_b)
    [@away, teams(:team_c), teams(:team_d)].each do |team|
      team.update!(league: "nfl", sport: "football")
    end
    @slot = Nfl::LiveScores::PollCycle::Slot.new(year: 2026, season_type: 1, week: 4)
  end

  test "writes a game, its scoring events, and the resulting score" do
    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    game = Game.find_by(external_id: "EV1")
    assert_not_nil game
    assert_equal "team-a-vs-team-b-pre4", game.slug
    assert_equal 10, game.home_score
    assert_equal 7, game.away_score
    assert_equal 3, game.goals.count
    assert_equal 1, result.games_seen
    assert_empty result.anomalies
    assert_equal %w[score score score], result.changes.map(&:kind)
  end

  # The idempotency guarantee the twelve-hour loop depends on: run it again and
  # nothing is written, because every play carries ESPN's own id under a unique
  # index.
  test "a second identical cycle writes nothing" do
    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_no_difference -> { Goal.count } do
      result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)
      assert result.quiet?
      assert_empty result.changes
    end
  end

  # ESPN withdraws plays when a touchdown is overturned on review. A Goal that
  # outlived its play would leave a contest scored on points nobody scored.
  test "a play the feed withdraws is removed and the score comes back down" do
    full = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: full)
    assert_equal 10, Game.find_by(external_id: "EV1").home_score

    # Same game, minus the touchdown, with the score corrected to match.
    reversed = StubClient.new(
      scoreboard: scoreboard(home: 3, away: 7),
      summaries: { "EV1" => { "scoringPlays" => summary["scoringPlays"].reject { |p| p["id"] == "P1" } } }
    )
    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: reversed)

    game = Game.find_by(external_id: "EV1")
    assert_equal 3, game.home_score
    assert_equal 2, game.goals.count
    assert_includes result.changes.map(&:kind), "reversed"
  end

  # The expensive half of a cycle is the per-game summary request. A game whose
  # score has not moved must not cost one — this is what keeps a full Sunday
  # slate at roughly one request per cycle.
  test "spends no summary request on a game whose score has not moved" do
    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)
    assert_equal ["EV1"], client.summary_calls

    quiet = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: quiet)

    assert_empty quiet.summary_calls
  end

  test "propagates the score onto every slate matchup for that game" do
    slate = slates(:one)
    game_slug = "team-a-vs-team-b-pre4"
    home_matchup = SlateMatchup.create!(slate: slate, team_slug: @home.slug,
                                        opponent_team_slug: @away.slug, game_slug: game_slug,
                                        slug: "sm-home-pre4", rank: 1)
    away_matchup = SlateMatchup.create!(slate: slate, team_slug: @away.slug,
                                        opponent_team_slug: @home.slug, game_slug: game_slug,
                                        slug: "sm-away-pre4", rank: 2)

    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_equal 10, home_matchup.reload.goals
    assert_equal 7, away_matchup.reload.goals
  end

  # A game marked final bypasses the Goal callbacks, so the matchup flip has to
  # be explicit — the same reason the admin console's complete_game does it.
  test "a completed game flips its matchups to completed" do
    slate = slates(:one)
    matchup = SlateMatchup.create!(slate: slate, team_slug: @home.slug, opponent_team_slug: @away.slug,
                                   game_slug: "team-a-vs-team-b-pre4", slug: "sm-final-pre4", rank: 1)

    client = StubClient.new(
      scoreboard: scoreboard(home: 10, away: 7, state: "post", completed: true),
      summaries: { "EV1" => summary }
    )
    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_equal "completed", Game.find_by(external_id: "EV1").status
    assert_equal "completed", matchup.reload.status
    assert_includes result.changes.map(&:kind), "final"
  end

  # An unmappable team is REPORTED, never silently skipped. A team that quietly
  # never scores is the worst failure available in a feed that settles money.
  test "an unknown team is reported as an anomaly rather than dropped in silence" do
    board = scoreboard(home: 10, away: 7)
    board["events"][0]["competitions"][0]["competitors"][0]["team"]["abbreviation"] = "ZZZ"
    client = StubClient.new(scoreboard: board)

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_equal ["unknown_team"], result.anomalies.map(&:kind)
    assert_equal 0, Game.where(external_id: "EV1").count
  end

  # When our summed events and the feed's total disagree, something was skipped.
  # Saying so beats serving a confidently wrong scoreboard.
  test "reports drift when our summed score disagrees with the feed" do
    client = StubClient.new(
      scoreboard: scoreboard(home: 99, away: 7),
      summaries: { "EV1" => summary }
    )

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_equal ["score_drift"], result.anomalies.map(&:kind)
    assert_match(/ESPN 7-99/, result.anomalies.first.detail)
  end

  test "one game failing to fetch does not abort the rest of the cycle" do
    board = scoreboard(home: 10, away: 7)
    board["events"] << board["events"].first.deep_dup.tap { |e| e["id"] = "EV2" }
    board["events"][1]["competitions"][0]["competitors"][0]["team"]["abbreviation"] = "TMC"
    board["events"][1]["competitions"][0]["competitors"][1]["team"]["abbreviation"] = "TMD"

    client = StubClient.new(scoreboard: board, summaries: { "EV1" => summary })
    def client.summary(event_id:)
      raise Nfl::Espn::Client::Error, "boom" if event_id == "EV1"

      super
    end

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    # EV1 reports fetch_failed. EV2 goes on to be processed — which is the point
    # of the test — and reports drift of its own, because the stub returns it no
    # scoring plays to back its scoreboard total. Both anomalies are correct, so
    # this asserts the first is PRESENT rather than that it is alone.
    assert_includes result.anomalies.map(&:kind), "fetch_failed"
    assert_equal 2, result.games_seen
    assert_not_nil Game.find_by(external_id: "EV2")
  end

  # ── THE DEGRADED FEED ────────────────────────────────────────────────────
  # A 200, valid JSON, no scoringPlays key. Reproduced against a game holding
  # goals it wiped them: 3 -> 0, score 10-7 -> 0-0, with ZERO anomalies, because
  # a blank scoreboard score also parsed to 0 and drift then agreed with itself.

  test "a summary with no scoringPlays key does NOT wipe the goals we hold" do
    seed = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: seed)
    game = Game.find_by(external_id: "EV1")
    assert_equal 3, game.goals.count

    degraded = StubClient.new(
      scoreboard: scoreboard(home: 10, away: 7),
      summaries: { "EV1" => { "header" => {} } }   # valid JSON, key absent
    )
    # Force the summary to be fetched at all.
    game.update!(home_score: 0, away_score: 0)
    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: degraded)

    assert_equal 3, game.reload.goals.count, "a degraded response must not delete goals"
    assert_includes result.anomalies.map(&:kind), "degraded_feed",
      "and it must SAY so — the wipe was silent, which is what made it dangerous"
  end

  test "a feed reporting zero plays for a game we hold scores on is refused" do
    seed = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: seed)
    game = Game.find_by(external_id: "EV1")
    game.update!(home_score: 0, away_score: 0)

    empty = StubClient.new(
      scoreboard: scoreboard(home: 10, away: 7),
      summaries: { "EV1" => { "scoringPlays" => [] } }
    )
    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: empty)

    assert_equal 3, game.reload.goals.count
    assert_includes result.anomalies.map(&:kind), "degraded_feed"
  end

  # The worst shape of all: the same degraded payload with completed:true used to
  # FINALISE a contest game at 0-0 and flip its matchups, silently.
  test "a degraded response cannot finalise a game at nothing" do
    seed = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: seed)
    game = Game.find_by(external_id: "EV1")
    game.update!(home_score: 0, away_score: 0)

    degraded = StubClient.new(
      scoreboard: scoreboard(home: 10, away: 7, state: "post", completed: true),
      summaries: { "EV1" => { "header" => {} } }
    )
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: degraded)

    game.reload
    assert_equal 3, game.goals.count, "the goals must survive"
    refute_equal "completed", game.status,
      "a game whose score we cannot reconcile must not be SETTLED — finalising " \
      "flips every matchup and re-scores every contest on a number one side " \
      "of the system does not believe"
  end

  test "a clean final still settles normally" do
    client = StubClient.new(
      scoreboard: scoreboard(home: 10, away: 7, state: "post", completed: true),
      summaries: { "EV1" => summary }
    )

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_equal "completed", Game.find_by(external_id: "EV1").status
    assert_includes result.changes.map(&:kind), "final"
    assert_empty result.anomalies
  end

  # A blank score on a game the feed calls LIVE is a degraded response, not 0-0.
  test "a blank score on a live game is an anomaly, not a zero" do
    board = scoreboard(home: 10, away: 7)
    board["events"][0]["competitions"][0]["competitors"].each { |c| c["score"] = "" }
    client = StubClient.new(scoreboard: board, summaries: { "EV1" => summary })

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_includes result.anomalies.map(&:kind), "degraded_feed"
    assert_empty client.summary_calls, "a score we cannot read must not drive reconciliation"
  end

  test "a scheduled game with no score yet is NOT an anomaly" do
    board = scoreboard(home: 10, away: 7, state: "pre")
    board["events"][0]["competitions"][0]["competitors"].each { |c| c["score"] = "" }

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: StubClient.new(scoreboard: board))

    assert_empty result.anomalies
  end

  # The mirror of the degraded SUMMARY above, and worse: `upsert_game` wrote the
  # feed's "completed" before the score guard ran, latching `was_completed` so
  # `finalise` could never fire -- FINAL on the board, matchups open, forever.
  test "a degraded scoreboard cannot strand a game FINAL and unsettled" do
    matchup = SlateMatchup.create!(slate: slates(:one), team_slug: @home.slug,
                                   opponent_team_slug: @away.slug, rank: 1,
                                   game_slug: "team-a-vs-team-b-pre4", slug: "sm-degraded-pre4")
    board = scoreboard(home: 10, away: 7, state: "post", completed: true)
    board["events"][0]["competitions"][0]["competitors"].each { |c| c["score"] = "" }
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: StubClient.new(scoreboard: board))

    clean = StubClient.new(scoreboard: scoreboard(home: 10, away: 7, state: "post", completed: true),
                           summaries: { "EV1" => summary })
    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: clean)

    assert_includes result.changes.map(&:kind), "final", "the next clean cycle must still settle it"
    assert_equal "completed", matchup.reload.status
  end

  # ── MONOTONIC STATE ──────────────────────────────────────────────────────
  test "a stale row cannot un-complete a finished game or re-fire FINAL" do
    final = StubClient.new(
      scoreboard: scoreboard(home: 10, away: 7, state: "post", completed: true),
      summaries: { "EV1" => summary }
    )
    first = Nfl::LiveScores::PollCycle.call(slot: @slot, client: final)
    assert_includes first.changes.map(&:kind), "final"

    stale = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })
    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: stale)

    assert_equal "completed", Game.find_by(external_id: "EV1").status
    assert_includes result.anomalies.map(&:kind), "status_regression"
    refute_includes result.changes.map(&:kind), "final", "FINAL must not broadcast twice"
  end

  # The finalise-once guard had ZERO coverage: mutating it to `false` left the
  # suite green. This is the test that bites.
  test "finalise fires exactly once across repeated cycles" do
    client = StubClient.new(
      scoreboard: scoreboard(home: 10, away: 7, state: "post", completed: true),
      summaries: { "EV1" => summary }
    )

    first = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)
    second = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)
    third = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_equal 1, first.changes.count { |c| c.kind == "final" }
    assert_equal 0, second.changes.count { |c| c.kind == "final" }
    assert_equal 0, third.changes.count { |c| c.kind == "final" }
  end

  # ── IDEMPOTENCY THAT REACHES THE DEDUPE PATH ─────────────────────────────
  # The old "second identical cycle writes nothing" test never got here:
  # score_disagrees? short-circuited before sync_scoring_plays ran, so deleting
  # the dedupe line left it green. This one forces the summary to be read while
  # the game already holds two of the three plays.
  test "a summary repeating plays we already hold writes only the new one" do
    seed = StubClient.new(
      scoreboard: scoreboard(home: 7, away: 7),
      summaries: { "EV1" => { "scoringPlays" => summary["scoringPlays"].first(2) } }
    )
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: seed)
    game = Game.find_by(external_id: "EV1")
    assert_equal 2, game.goals.count

    full = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })

    assert_difference -> { Goal.count }, 1 do
      Nfl::LiveScores::PollCycle.call(slot: @slot, client: full)
    end
    assert_equal %w[P1 P2 P3], game.reload.goals.order(:id).pluck(:external_id)
  end

  # ── THE TRY, FOLDED INTO THE TOUCHDOWN ───────────────────────────────────
  # ESPN does not report the extra point as its own play. It folds the try into
  # the touchdown that earned it and RESTATES that same play id: 6 while the
  # kick is in the air, 7 once it is good. Reconciliation that only ever
  # CREATES therefore leaves a touchdown caught mid-try a point light for the
  # rest of the game — and reports score_drift every cycle from then on.
  #
  # Measured on production, 2026-08-27 preseason week 4: four touchdowns across
  # two live games stored 6 while the feed read 7 (plays 401873299636,
  # 401873298852, 4018732982406, 4018732982623). The /live board showed CLE 26
  # against ESPN's 27, and every contest scored off it was a point light.

  test "an extra point amended onto a play we already hold is picked up" do
    mid_try = StubClient.new(
      scoreboard: scoreboard(home: 6, away: 0),
      summaries: { "EV1" => { "scoringPlays" => [play("P1", "TMA", home: 6, away: 0, type: "TD")] } }
    )
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: mid_try)
    game = Game.find_by(external_id: "EV1")
    assert_equal 6, game.home_score

    kicked = StubClient.new(
      scoreboard: scoreboard(home: 7, away: 0),
      summaries: { "EV1" => { "scoringPlays" => [play("P1", "TMA", home: 7, away: 0, type: "TD")] } }
    )
    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: kicked)

    assert_equal 1, game.reload.goals.count, "the try is folded into the play, not a second row"
    assert_equal 7, game.goals.first.points
    assert_equal 7, game.home_score
    assert_empty result.anomalies, "the board must AGREE with the feed, not drift against it"
  end

  # The amendment is reported as what it was worth — the point, not the seven —
  # and labelled by the delta. Printing "touchdown +1" would name the wrong half
  # of the play; the watch is meant to read "the extra point landed".
  test "the amendment is reported as the point it added, labelled as the try" do
    seed = StubClient.new(
      scoreboard: scoreboard(home: 6, away: 0),
      summaries: { "EV1" => { "scoringPlays" => [play("P1", "TMA", home: 6, away: 0, type: "TD")] } }
    )
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: seed)

    kicked = StubClient.new(
      scoreboard: scoreboard(home: 7, away: 0),
      summaries: { "EV1" => { "scoringPlays" => [play("P1", "TMA", home: 7, away: 0, type: "TD")] } }
    )
    change = Nfl::LiveScores::PollCycle.call(slot: @slot, client: kicked).changes.sole

    assert_equal "score", change.kind
    assert_equal 1, change.points
    assert_equal "pat", change.scoring_type
    assert_equal 7, change.home_score
  end

  # A two-point conversion is the same amendment two points wide, and it must
  # not be labelled "safety" just because POINTS_TO_TYPE maps 2 that way — the
  # points went to the team that scored, which is what a safety never does.
  test "a two-point conversion amended onto the touchdown is labelled as one" do
    seed = StubClient.new(
      scoreboard: scoreboard(home: 6, away: 0),
      summaries: { "EV1" => { "scoringPlays" => [play("P1", "TMA", home: 6, away: 0, type: "TD")] } }
    )
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: seed)

    converted = StubClient.new(
      scoreboard: scoreboard(home: 8, away: 0),
      summaries: { "EV1" => { "scoringPlays" => [play("P1", "TMA", home: 8, away: 0, type: "TD")] } }
    )
    change = Nfl::LiveScores::PollCycle.call(slot: @slot, client: converted).changes.sole

    assert_equal 2, change.points
    assert_equal "two_point", change.scoring_type
    assert_equal 8, Game.find_by(external_id: "EV1").home_score
  end

  # Amendments run BOTH ways. A try wiped out on review takes its point back,
  # and the play keeps its own type, because what came off was the try.
  test "a play restated DOWNWARD takes its points back off the board" do
    seed = StubClient.new(
      scoreboard: scoreboard(home: 7, away: 0),
      summaries: { "EV1" => { "scoringPlays" => [play("P1", "TMA", home: 7, away: 0, type: "TD")] } }
    )
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: seed)

    reduced = StubClient.new(
      scoreboard: scoreboard(home: 6, away: 0),
      summaries: { "EV1" => { "scoringPlays" => [play("P1", "TMA", home: 6, away: 0, type: "TD")] } }
    )
    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: reduced)

    game = Game.find_by(external_id: "EV1")
    assert_equal 6, game.home_score
    assert_equal 6, game.goals.sole.points
    assert_equal(-1, result.changes.sole.points)
    assert_empty result.anomalies
  end

  # The amendment must reach the contests, not stop at the game row — the whole
  # reason the missing point mattered is that entries were scored off it.
  test "an amended point propagates onto the slate matchups" do
    matchup = SlateMatchup.create!(slate: slates(:one), team_slug: @home.slug,
                                   opponent_team_slug: @away.slug, rank: 1,
                                   game_slug: "team-a-vs-team-b-pre4", slug: "sm-try-pre4")
    seed = StubClient.new(
      scoreboard: scoreboard(home: 6, away: 0),
      summaries: { "EV1" => { "scoringPlays" => [play("P1", "TMA", home: 6, away: 0, type: "TD")] } }
    )
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: seed)
    assert_equal 6, matchup.reload.goals

    kicked = StubClient.new(
      scoreboard: scoreboard(home: 7, away: 0),
      summaries: { "EV1" => { "scoringPlays" => [play("P1", "TMA", home: 7, away: 0, type: "TD")] } }
    )
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: kicked)

    assert_equal 7, matchup.reload.goals
  end

  # A ONE-POINT SAFETY ON A TRY is worth exactly what a kicked extra point is
  # worth, so the parser's points-based fallback calls it a `pat` until ESPN
  # supplies the abbreviation. The correction that follows moves no points: it
  # must land on the row and print NOTHING, because a scoring line worth +0 is
  # noise in a twelve-hour scrollback.
  test "a play the feed re-labels is corrected without reporting a score" do
    untyped = play("P1", "TMA", home: 1, away: 0, type: "TD").except("type")
    seed = StubClient.new(scoreboard: scoreboard(home: 1, away: 0),
                          summaries: { "EV1" => { "scoringPlays" => [untyped] } })
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: seed)
    game = Game.find_by(external_id: "EV1")
    assert_equal "pat", game.goals.sole.scoring_type

    # Forces the summary to be read: a game whose total has not moved costs no
    # summary request, and a re-label does not move a total.
    game.update!(home_score: 0)
    labelled = StubClient.new(
      scoreboard: scoreboard(home: 1, away: 0),
      summaries: { "EV1" => { "scoringPlays" => [play("P1", "TMA", home: 1, away: 0, type: "SF")] } }
    )
    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: labelled)

    assert_equal "safety", game.goals.sole.scoring_type
    assert_empty result.changes, "a correction worth no points is not a scoring line"
  end

  # AMENDING MUST NOT COST IDEMPOTENCY. A play the feed repeats unchanged is
  # still nothing — no write, no line in a twelve-hour scrollback.
  test "a play repeated unchanged is not re-reported as an amendment" do
    seed = StubClient.new(
      scoreboard: scoreboard(home: 7, away: 7),
      summaries: { "EV1" => { "scoringPlays" => summary["scoringPlays"].first(2) } }
    )
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: seed)
    game = Game.find_by(external_id: "EV1")

    # Forces the summary to be read while every play in it is already held.
    game.update!(home_score: 0, away_score: 0)
    full = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })
    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: full)

    assert_equal 1, result.changes.length, "only the new play may report"
    assert_equal "P3", game.reload.goals.order(:id).last.external_id
  end

  # An id-less play stores "" — which the partial index covers — so the second
  # one anywhere in the league collides GLOBALLY. Dropped at the parse seam.
  test "a play with no id is dropped rather than stored as a colliding blank" do
    plays = summary["scoringPlays"].map(&:dup)
    plays[0] = plays[0].merge("id" => "")
    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => { "scoringPlays" => plays } })

    Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    ids = Game.find_by(external_id: "EV1").goals.pluck(:external_id)
    refute_includes ids, ""
    assert_equal %w[P2 P3], ids.sort
  end

  private

  def scoreboard(home:, away:, state: "in", completed: false)
    {
      "events" => [{
        "id" => "EV1",
        "date" => "2026-08-27T23:00Z",
        "season" => { "year" => 2026, "type" => 1 },
        "week" => { "number" => 4 },
        "competitions" => [{
          "status" => { "period" => 3, "displayClock" => "8:42",
                        "type" => { "state" => state, "completed" => completed, "shortDetail" => "Q3 8:42" } },
          "competitors" => [
            { "homeAway" => "home", "score" => home.to_s, "team" => { "abbreviation" => "TMA" } },
            { "homeAway" => "away", "score" => away.to_s, "team" => { "abbreviation" => "TMB" } }
          ]
        }]
      }]
    }
  end

  # Home 10 (TD+kick, then FG), away 7 (TD+kick).
  def summary
    {
      "scoringPlays" => [
        play("P1", "TMA", home: 7,  away: 0, type: "TD"),
        play("P2", "TMB", home: 7,  away: 7, type: "TD"),
        play("P3", "TMA", home: 10, away: 7, type: "FG")
      ]
    }
  end

  def play(id, team, home:, away:, type:)
    {
      "id" => id, "type" => { "abbreviation" => type },
      "team" => { "abbreviation" => team },
      "homeScore" => home, "awayScore" => away,
      "period" => { "number" => 2 }, "clock" => { "displayValue" => "5:28" },
      "text" => "#{team} scored"
    }
  end
end
