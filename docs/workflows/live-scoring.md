# Live NFL Scoring

How a real touchdown becomes a number on a contest standing, what runs it, and
what it refuses to do.

## The chain

```
ESPN scoreboard  ->  Nfl::LiveScores::PollCycle
                       -> Goal (points, scoring_type, external_id)
                       -> Game#update_scores_from_goals!      sums points
                       -> Game#update_slate_matchups!         sets SlateMatchup#goals
                       -> Game#score_affected_contests!       re-scores open contests
                       -> Entry#score! -> Selection#compute_points!
                     and, in parallel:
                       -> Contest::LiveBroadcast   the per-contest live page
                       -> Nfl::LiveBroadcast       the league board at /live
```

Nothing in the poller writes a score directly. It writes `Goal` rows and the
existing callbacks carry them the rest of the way, which is why a hand-recorded
goal and a fed one behave identically.

## The surfaces

| What | Where |
|---|---|
| League scoreboard | `GET /live` — public, read-only, no sign-in |
| One cycle, printed as a delta | `bin/nfl-live-poll` |
| Score injectors (non-production only) | `POST /dev/live_scores/{record,clear_game,conclude_game}` |
| The operator act | `live-score-watch` (mcritchie-studio SOP, Avi) |

## `bin/nfl-live-poll`

```bash
bin/nfl-live-poll                  # the slot ESPN considers current
bin/nfl-live-poll --slot 2026:1:4  # year:season_type:week  (1=pre 2=reg 3=post)
bin/nfl-live-poll --json           # machine-readable
bin/nfl-live-poll --quiet          # print nothing when nothing changed
```

Exit 0 when the cycle completed, whether or not anything changed. Exit 1 only
when the cycle could not run at all. **Anomalies are reported, never fatal** — a
feed we do not own will have bad minutes and a bad minute must not end a watch.

**It is idempotent.** Every scoring event is keyed on ESPN's own play id under a
unique partial index, so a second identical cycle writes nothing and an
interrupted one resumes by being run again.

## THERE IS NO SCHEDULER

`config/schedule.yml` has no NFL entry, and `bin/nfl-live-poll` is the only
non-test caller of `Nfl::LiveScores::PollCycle`. **An operator running the
`live-score-watch` act is the sole path by which production contests re-score.**

That is a deliberate current state, not an oversight — but it means the act's
target matters enormously, and the SOP makes the environment explicit in every
command for that reason. If this ever moves to a cron trigger, the SOP's own
design note is the place to start.

## The anomaly vocabulary

Seven kinds. The cycle reports and continues; none is fatal.

| Kind | Means | What to do |
|---|---|---|
| `fetch_failed` | One game's summary did not arrive | Ignore once. Twice on the same game: report it. |
| `unknown_team` | An abbreviation resolved to no team | **Escalate.** A team that cannot be matched silently never scores. |
| `score_drift` | Our summed events disagree with the feed's total | Ignore a single cycle mid-play; persisting means a play was missed. |
| `degraded_feed` | The feed declined to answer — an absent `scoringPlays` key, zero plays against goals we hold, or a blank score on a live game | The cycle **refuses to act**. Investigate if it persists. |
| `status_regression` | A stale row reported an earlier state for a completed game | Informational; the game keeps its completed status. |
| `unsettled_final` | The feed says FINAL but our events disagree with its total | The game is **not settled**. It settles on the next reconciling cycle. |
| `cycle_error` | An unexpected exception, captured to `ErrorLog` | A bug. Read the ErrorLog. |

## What it refuses to do

These are guards with reproductions behind them, not defensive padding.

- **It will not wipe scores on a degraded response.** A 200 with valid JSON and
  no `scoringPlays` key once deleted every goal a game held — 3 to 0, 10-7 to
  0-0 — silently, because a blank scoreboard score also parsed to 0 and the
  drift check then compared two zeros and agreed. The parse seam now
  distinguishes "no plays" from "no answer", the reconciler refuses to sweep to
  nothing, and a blank score on a live game is an anomaly rather than a zero.
- **It will not settle a game it cannot reconcile.** Finalising flips every
  matchup and re-scores every contest. Doing that while our events disagree with
  the feed settles a contest on a number one side of the system does not
  believe, so the game stays open and the disagreement is reported.
- **It will not un-complete a finished game.** A stale scoreboard row would
  otherwise re-open a settled game and re-fire the FINAL broadcast.
- **It will not store an id-less play.** `play["id"].to_s` yields `""`, which
  the unique index's `WHERE external_id IS NOT NULL` predicate covers — so a
  second id-less play anywhere in the league would collide across games.

## The external dependency

ESPN's public scoreboard and summary endpoints. No key, no account, no contract.

**It refuses Ruby.** Measured against the live endpoint: no `User-Agent` → 403;
a custom `TurfMonster/1.0` → 403; a Chrome string sent from Ruby → 403;
`curl/8.7.1` → 200. `Nfl::Espn::Client::USER_AGENT` carries an accepted agent
and `test/services/nfl/espn/client_test.rb` asserts it — the same gap once left
`Nfl::FetchHistoricalScores` broken in main, because its only test covered the
pure parse seam and could not see a transport failure.

Treat the feed as unowned: undocumented, unversioned, and free to change. That
is also why it should not be the last word on a settled contest.
