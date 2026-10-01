require "test_helper"

# [integration] One polling cycle, across its whole I/O boundary: an ESPN
# payload in, Game + Goal rows and SlateMatchup propagation out.
#
# The HTTP client is stubbed — the point is the seam BELOW it. What the network
# actually returns is pinned by the unit tests over the parse seams.
class NflLiveScoresPollTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

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

  # --- studio recap push -------------------------------------------------
  # The hub push rides along with a finalisation. Everything below is about one
  # property: it must never cost a contest its settlement.

  def final_client
    StubClient.new(
      scoreboard: scoreboard(home: 10, away: 7, state: "post", completed: true),
      summaries: { "EV1" => summary }
    )
  end

  test "a settled game enqueues a recap push" do
    ENV["AGENT_API_SECRET"] = "test-secret"

    assert_enqueued_with(job: Studio::GameRecapPushJob) do
      Nfl::LiveScores::PollCycle.call(slot: @slot, client: final_client)
    end
  ensure
    ENV.delete("AGENT_API_SECRET")
  end

  test "the push is skipped silently when no secret is configured" do
    ENV.delete("AGENT_API_SECRET")

    result = nil
    assert_no_enqueued_jobs only: Studio::GameRecapPushJob do
      result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: final_client)
    end

    # Skipped, not failed — an unconfigured stack scores exactly as it always did.
    assert_empty result.anomalies
    assert_equal "completed", Game.find_by(external_id: "EV1").status
  end

  # The point of the whole design: the hub is allowed to be down.
  test "a failing enqueue is an anomaly and still settles the game" do
    ENV["AGENT_API_SECRET"] = "test-secret"
    Studio::GameRecapPushJob.stub(:perform_later, ->(*) { raise RuntimeError, "redis is down" }) do
      result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: final_client)

      # The game still settled and still reported FINAL.
      assert_equal "completed", Game.find_by(external_id: "EV1").status
      assert_includes result.changes.map(&:kind), "final"

      # And the failure was reported rather than swallowed.
      push_anomalies = result.anomalies.select { |a| a.kind == "recap_push_failed" }
      assert_equal 1, push_anomalies.length
      assert_match "redis is down", push_anomalies.first.detail
    end
  ensure
    ENV.delete("AGENT_API_SECRET")
  end

  test "a game that does not settle enqueues nothing" do
    ENV["AGENT_API_SECRET"] = "test-secret"
    client = StubClient.new(
      scoreboard: scoreboard(home: 10, away: 7),
      summaries: { "EV1" => summary }
    )

    assert_no_enqueued_jobs only: Studio::GameRecapPushJob do
      Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)
    end
  ensure
    ENV.delete("AGENT_API_SECRET")
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

  # ── THE SETTLEMENT SEAM ───────────────────────────────────────────────────
  #
  # GRADING AND SETTLEMENT ARE SEPARATE ACTS, and a cycle must not reach across
  # the boundary between them. The cycle is idempotent about SCORING EVENTS —
  # plays are keyed on ESPN's own id under a unique index — but not about their
  # CONSEQUENCES: one new or withdrawn play re-sums the game and rewrites every
  # SlateMatchup#goals it feeds. Doing that under a contest whose ranks and
  # payouts are already final leaves a leaderboard that disagrees with the money
  # that was paid out, and `Contest#grade!` cannot repair it — it raises on a
  # settled contest by design.
  #
  # These live on the CYCLE and not on the scheduled job on purpose: the job is
  # not the only caller. `bin/nfl-live-poll --slot` is what an operator reaches
  # for when repairing a historical week, which is exactly when a settled contest
  # is most likely to be in range.

  test "refuses a slot whose contest has already settled, before writing anything" do
    settled_contest_on("team-a-vs-team-b-pre4")
    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })

    result = nil
    assert_no_difference ["Goal.count", "Game.count"] do
      result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)
    end

    assert_equal ["settled_contest"], result.anomalies.map(&:kind)
    assert_match contests(:one).slug, result.anomalies.first.detail
    assert_empty result.changes
    assert_empty client.summary_calls, "it refused before spending a request"
    assert_equal 1, result.games_seen, "the scoreboard WAS read — nothing was written"
  end

  # THE CONTROL. Without it the test above passes just as well against a cycle
  # that refuses every slot, which would stop all live scoring — the defect, in a
  # new costume.
  test "still polls a slot whose contest is merely open" do
    matchup_on("team-a-vs-team-b-pre4")
    assert_predicate contests(:one).reload, :open?
    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_empty result.anomalies, "an open contest is not a reason to refuse a slot"
    assert_equal 3, Game.find_by(external_id: "EV1").goals.count
  end

  # ── THE VETO THAT BOUNCED THIS PR ─────────────────────────────────────────
  #
  # `Slate has_many :contests` and `contests.slate_id` is NOT unique, so one
  # slate carries several — the ordinary multi-tier pattern. The refusal used to
  # be decided ONCE PER CYCLE and returned before `rows.each`, so a single
  # settled contest anywhere on the slot stopped every game on it from being
  # written at all. Measured by the reviewer: two contests on one slate, one
  # settled and one open, `anomalies == ["settled_contest"]` and
  # `Game.find_by(external_id: "EV1")` NIL — the row was never even created.
  #
  # THAT RE-CREATES THE ORIGINAL BUG. An admin grades tier A on Sunday evening;
  # tier B is still open with paid entries; Monday Night Football is on the same
  # slate. Every tick thereafter refused, so MNF was never scored for anyone.
  #
  # SO THE DECISION IS MADE FROM THE CONTEST POPULATION, PER GAME: a game is
  # skipped only when EVERY contest that renders it is settled. The two contests
  # share their SlateMatchup rows — one row cannot be both frozen and current —
  # so when a live open contest needs the slot, the matchups move. What stays
  # frozen is what the money actually stands on: `score_affected_contests!`
  # scopes to `status: [:open]`, so the settled contest's own stored
  # `entries.score` and `selections.points` are never recomputed.
  test "an open contest sharing a slate with a settled one still gets scored" do
    matchup = matchup_on("team-a-vs-team-b-pre4", turf_score: 2.0)
    open_contest = Contest.create!(name: "Open Tier", slug: "open-tier", contest_type: "medium",
                                   status: "open", slate: slates(:one), max_entries: 9,
                                   entry_fee_cents: 1900)
    open_entry = open_contest.entries.create!(user: users(:alex), status: :active, score: 0.0)
    open_entry.selections.create!(slate_matchup: matchup)

    # The fixture contest on the SAME slate, graded. Its two fixture entries hold
    # score 1.5 and carry NO selections, so a re-score would recompute them to
    # 0.0 — which makes "unchanged at 1.5" a real assertion rather than a tautology.
    settled = contests(:one)
    settled.update!(status: "settled")
    assert_equal [1.5, 1.5], settled.entries.order(:id).map { |e| e.score.to_f }

    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    game = Game.find_by(external_id: "EV1")
    assert_not_nil game, "the row was never created under the per-cycle veto"
    assert_equal 3, game.goals.count, "the open contest's slot has to be scored"
    assert_in_delta 20.0, open_entry.reload.score.to_f, 0.01,
                    "10 points x 2.0 turf_score — the open tier scored"
    assert_equal [1.5, 1.5], settled.entries.order(:id).map { |e| e.score.to_f },
                 "the settled tier's stored scores are what its payouts stand on"
    assert_equal ["settled_contest_coscored"], result.anomalies.map(&:kind),
                 "reported, because a settled contest's matchups did move"
    assert_match settled.slug, result.anomalies.first.detail
  end

  # THE PER-GAME CONTROL. One slot, two games: one on a slate whose only contest
  # is settled, one on a slate with no contest at all. The settled one is skipped
  # and the other is written — which is the property a per-cycle refusal could
  # not have.
  test "a settled game is skipped without costing the other games on the slot" do
    settled_contest_on("team-a-vs-team-b-pre4")
    client = StubClient.new(scoreboard: two_game_scoreboard, summaries: { "EV2" => summary_for("TMC", "TMD") })

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_nil Game.find_by(external_id: "EV1"), "the settled game is still refused"
    assert_not_nil Game.find_by(external_id: "EV2"), "its neighbour must not pay for that"
    assert_equal 3, Game.find_by(external_id: "EV2").goals.count
    assert_equal ["settled_contest"], result.anomalies.map(&:kind), "one anomaly, naming the skipped game"
    assert_match "team-a-vs-team-b-pre4", result.anomalies.first.detail
    assert_equal 2, result.games_seen
    assert_equal ["EV2"], client.summary_calls, "no request was spent on the skipped game"
  end

  # A PENDING CONTEST IS NOT AN OPEN ONE. `Contest#status` is pending/open/settled
  # and only `open` is scored (`Game#score_affected_contests!`), so a pending
  # contest cannot unblock a settled one — otherwise a tier that has not launched
  # would re-open a graded tier's matchups.
  test "a pending contest does not unblock a settled slate" do
    settled_contest_on("team-a-vs-team-b-pre4")
    Contest.create!(name: "Pending Tier", slug: "pending-tier", contest_type: "medium",
                    status: "pending", slate: slates(:one), max_entries: 9, entry_fee_cents: 1900)
    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_equal ["settled_contest"], result.anomalies.map(&:kind)
    assert_equal 0, Goal.count
  end

  # A CONTEST IS SETTLED IN THE DATABASE BEFORE IT IS SETTLED ON CHAIN.
  # `Contest#grade!` writes `status: "settled"` and only then attempts
  # `settle_onchain!`, which can legitimately still be pending — so a graded,
  # paid-out contest routinely reads `onchain_settled: false`. A guard keyed on
  # the on-chain flag would walk straight through it.
  test "settlement is read from status, not from onchain_settled" do
    contest = settled_contest_on("team-a-vs-team-b-pre4")
    contest.update!(onchain_settled: false)
    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_equal ["settled_contest"], result.anomalies.map(&:kind)
    assert_equal 0, Goal.count
  end

  # The matchup can name a game slug before any Game row exists for it — that is
  # how the odds CSV seeds a slate. The guard has to resolve the slug a row WOULD
  # take, not only the row we already hold, or it walks past exactly that case.
  test "refuses a settled contest whose matchup names a game we do not hold yet" do
    assert_equal 0, Game.where(slug: "team-a-vs-team-b-pre4").count
    settled_contest_on("team-a-vs-team-b-pre4")
    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_equal ["settled_contest"], result.anomalies.map(&:kind)
    assert_equal 0, Game.where(external_id: "EV1").count, "the row was never created"
  end

  # AND THE OTHER HALF OF THE UNION. A game we already hold can carry a
  # DIFFERENT week than the feed row naming it — the NFL flexes games, and our
  # slug is computed from our own stored week. The matchup then points at the old
  # slug while the row computes the new one, so only the Game we hold by
  # `external_id` reaches the settled contest.
  test "refuses when the game we hold sits in a different week than the feed row" do
    Game.create!(external_id: "EV1", home_team_slug: @home.slug, away_team_slug: @away.slug,
                 season_year: 2026, season_type: 1, week: 3, status: "scheduled")
    settled_contest_on("team-a-vs-team-b-pre3")
    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_equal ["settled_contest"], result.anomalies.map(&:kind)
    assert_equal 0, Goal.count
    assert_equal 3, Game.find_by(external_id: "EV1").week, "the row was not re-slotted either"
  end

  # THE DELIBERATE OVERRIDE. An operator who has read the seam and decided
  # anyway can still repair a settled slot by hand. Nothing on a schedule passes
  # this flag.
  test "allow_settled lets an operator override the refusal on purpose" do
    settled_contest_on("team-a-vs-team-b-pre4")
    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client, allow_settled: true)

    assert_equal 3, Game.find_by(external_id: "EV1").goals.count
    refute_includes result.anomalies.map(&:kind), "settled_contest"
  end

  # A slot no contest touches is nobody's settlement, so the guard must not be a
  # blanket "is anything settled anywhere" check.
  test "a settled contest on an unrelated slate does not block the slot" do
    settled_contest_on("some-other-game-entirely")
    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_empty result.anomalies, "the guard must be scoped to THIS slot's contests"
    assert_equal 3, Game.find_by(external_id: "EV1").goals.count
  end

  # ── THE SITUATION ────────────────────────────────────────────────────────

  test "persists the down, the field position and who has the ball" do
    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7, situation: {
      "down" => 3, "distance" => 9, "possession" => "2",
      "downDistanceText" => "3rd & 9", "possessionText" => "TMB 13"
    }))

    Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    game = Game.find_by(external_id: "EV1")
    assert_equal "3rd & 9", game.down_distance
    assert_equal "TMB 13", game.possession_text
    assert_equal "team-b", game.possession_team_slug, "possession id 2 is the away competitor"
    assert_equal "TMB on TMB 13", game.possession_line
  end

  # THE NIL IS WRITTEN THROUGH, and this is the test that matters.
  #
  # ESPN drops the situation block the moment a game ends. Assigning it only
  # when present — the obvious `if row.down_distance` — would leave the last
  # snap of the fourth quarter frozen in the columns, and a card that has said
  # FINAL for an hour would still be announcing "4th & Goal" from the game's
  # last drive. The clearing is the whole reason the assignment is unconditional.
  test "a cycle with no situation clears the one it stored last" do
    stored = StubClient.new(scoreboard: scoreboard(home: 10, away: 7, situation: {
      "possession" => "2", "downDistanceText" => "4th & Goal", "possessionText" => "TMA 3"
    }))
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: stored)
    assert_equal "4th & Goal", Game.find_by(external_id: "EV1").down_distance

    dropped = StubClient.new(scoreboard: scoreboard(home: 10, away: 7, state: "post", completed: true))
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: dropped)

    game = Game.find_by(external_id: "EV1")
    assert_nil game.down_distance
    assert_nil game.possession_text
    assert_nil game.possession_team_slug
  end

  # AN UNMAPPED ABBREVIATION IS NOT A SLUG. TeamMap looks inside Team.nfl, so a
  # team we do not carry resolves to nothing — and storing the raw abbreviation
  # instead would put a value in the column that joins to no team, rendering an
  # uncoloured, unnamed possession line. Saying nothing is the honest answer,
  # and the yard line still stands on its own.
  test "possession by a team we do not carry stores no slug" do
    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7, situation: {
      "possession" => "9", "downDistanceText" => "1st & 10", "possessionText" => "TMA 40"
    }).tap { |sb|
      sb["events"][0]["competitions"][0]["competitors"] << {
        "id" => "9", "homeAway" => "home", "score" => "0", "team" => { "abbreviation" => "ZZZ" }
      }
    })

    Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    game = Game.find_by(external_id: "EV1")
    assert_nil game.possession_team_slug
    assert_equal "1st & 10", game.down_distance, "the rest of the situation still lands"
    assert_equal "TMA 40", game.possession_line, "the yard line stands on its own"
  end

  private

  # A SlateMatchup on the fixture slate pointing at `game_slug` — the link that
  # carries a score from a game to a contest's entries.
  def matchup_on(game_slug, turf_score: nil)
    SlateMatchup.create!(slate: slates(:one), team_slug: @home.slug,
                         opponent_team_slug: @away.slug, game_slug: game_slug,
                         slug: "sm-#{game_slug}", rank: 1, turf_score: turf_score)
  end

  # TWO games on one slot, which is what a per-game refusal needs and a
  # single-event board cannot express. EV1 is the TMA/TMB game the settled
  # contest's matchup names; EV2 is an unrelated TMC/TMD game on the same week.
  def two_game_scoreboard
    first = scoreboard(home: 10, away: 7).fetch("events").first
    second = Marshal.load(Marshal.dump(first))
    second["id"] = "EV2"
    competitors = second.dig("competitions", 0, "competitors")
    competitors[0]["team"]["abbreviation"] = "TMC"
    competitors[1]["team"]["abbreviation"] = "TMD"
    { "events" => [first, second] }
  end

  def summary_for(home_abbr, away_abbr)
    {
      "scoringPlays" => [
        play("P1", home_abbr, home: 7,  away: 0, type: "TD"),
        play("P2", away_abbr, home: 7,  away: 7, type: "TD"),
        play("P3", home_abbr, home: 10, away: 7, type: "FG")
      ]
    }
  end

  # The fixture contest, on that same slate, moved to the terminal state.
  # `update!` rather than `grade!`: grading is a separate act with its own
  # preconditions, and what this guard reads is the recorded status.
  def settled_contest_on(game_slug)
    matchup_on(game_slug)
    contests(:one).tap { |contest| contest.update!(status: "settled") }
  end

  def scoreboard(home:, away:, state: "in", completed: false, situation: :none)
    competition = {
      "status" => { "period" => 3, "displayClock" => "8:42",
                    "type" => { "state" => state, "completed" => completed, "shortDetail" => "Q3 8:42" } },
      "competitors" => [
        { "id" => "1", "homeAway" => "home", "score" => home.to_s, "team" => { "abbreviation" => "TMA" } },
        { "id" => "2", "homeAway" => "away", "score" => away.to_s, "team" => { "abbreviation" => "TMB" } }
      ]
    }
    # `:none` is the feed OMITTING the block, which is what a scheduled or
    # finished game actually sends — distinct from sending one with blank
    # fields, and the two have to be reachable separately.
    competition["situation"] = situation unless situation == :none

    {
      "events" => [{
        "id" => "EV1",
        "date" => "2026-08-27T23:00Z",
        "season" => { "year" => 2026, "type" => 1 },
        "week" => { "number" => 4 },
        "competitions" => [competition]
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

  # ── THE OTHER HALF OF THE SEAM: Row -> Goal ───────────────────────────────
  #
  # rows_from producing a scorer proves nothing about record_play persisting it.
  # This is the end of the chain the card reads from: ESPN prose in, columns out.
  test "a recorded play persists the scorer and the play description" do
    game = Game.create!(
      home_team_slug: teams(:team_a).slug, away_team_slug: teams(:team_b).slug,
      season_year: 2026, season_type: 1, week: 4, status: "in_progress"
    )
    row = Nfl::Espn::ScoringPlays::Row.new(
      external_id: "990001", team_abbr: "AAA", scoring_type: "touchdown",
      points: 6, period: 2, clock: "4:04",
      text: "Pat Passer 12 Yd pass from Someone Else (A Kicker Kick)",
      scorer: "Pat Passer", description: "12 yard receiving TD"
    )

    cycle = Nfl::LiveScores::PollCycle.allocate
    cycle.instance_variable_set(:@changes, [])
    cycle.instance_variable_set(:@anomalies, [])

    Nfl::Espn::TeamMap.stub :team_for, teams(:team_a) do
      cycle.send(:record_play, game, Struct.new(:detail).new(nil), row)
    end

    goal = game.goals.reload.last
    assert_equal "Pat Passer", goal.scorer_name
    assert_equal "12 yard receiving TD", goal.play_description
    # And the name was RESOLVED to the roster athlete the card draws.
    assert_equal "pat-passer", goal.scorer_slug
    assert goal.reveals_scorer?, "a touchdown with a named scorer earns the reveal"
  end

  test "a play whose scorer we cannot resolve still records the name" do
    game = Game.create!(
      home_team_slug: teams(:team_a).slug, away_team_slug: teams(:team_b).slug,
      season_year: 2026, season_type: 1, week: 5, status: "in_progress"
    )
    row = Nfl::Espn::ScoringPlays::Row.new(
      external_id: "990002", team_abbr: "AAA", scoring_type: "field_goal",
      points: 3, period: 3, clock: "1:00",
      text: "Practice Squad 41 Yd Field Goal",
      scorer: "Practice Squad", description: "41 yard field goal"
    )

    cycle = Nfl::LiveScores::PollCycle.allocate
    cycle.instance_variable_set(:@changes, [])
    cycle.instance_variable_set(:@anomalies, [])

    Nfl::Espn::TeamMap.stub :team_for, teams(:team_a) do
      cycle.send(:record_play, game, Struct.new(:detail).new(nil), row)
    end

    goal = game.goals.reload.last
    assert_equal "Practice Squad", goal.scorer_name
    assert_nil goal.scorer_slug, "no athlete record — the card draws initials"
    assert goal.reveals_scorer?, "we still know WHO scored, so it still reveals"
  end
end
