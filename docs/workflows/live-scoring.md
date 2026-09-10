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
| Focus-game priority list | `GET /admin/nfl/weeks` — admin only |
| One cycle, printed as a delta | `bin/nfl-live-poll` |
| Score injectors (non-production only) | `POST /dev/live_scores/{record,clear_game,conclude_game}` |
| The operator act | `live-score-watch` (mcritchie-studio SOP, Avi) |

## The focus game

`/live` leads with ONE game, drawn full width above the grid, and that game is
not also drawn in the grid — the board shows every game exactly once. Pressing
any card hands the panel over to it, takes it out of the grid, and scrolls the
page up to it. After first paint the choice is the reader's: it is Alpine state
(`nflLiveBoard`) declared on the page wrapper, outside both broadcast targets,
so a score cannot reset it.

Which game the board OPENS on is decided by `Live::FocusGame` — a ladder over
the week's games, first rung that answers wins:

| Rung | When | Picks |
|---|---|---|
| 1 · LIVE | a game is being played | the best-ranked one |
| 2 · IMMINENT | none is, and the next kickoff is inside the lead-in | the best-ranked game in that kickoff's wave |
| 3 · HOLDOVER | neither | the game that finished most recently |
| 4 · FALLBACK | nothing has finished either | the soonest upcoming game |

Two constants tune it per sport (`Live::FocusGame::POLICIES`) — for the NFL a
**12-hour lead-in** and a **90-minute wave**. Between them they produce the
league's actual rhythm without a line of calendar arithmetic: Tuesday to
Thursday the board leads with Thursday night (rung 4); Sunday morning the wave
narrows the field to the one o'clock kickoffs so a rank-1 night game cannot own
breakfast (rung 2); through the afternoon the best rank among the games actually
being played leads and moves on as each finishes (rung 1); Sunday night football
holds the board overnight (rung 3) and Monday night football takes it at 8:15
Monday morning, twelve hours before its kickoff (rung 2).

**The order is a tiebreak, never an override.** `games.focus_rank` is a
position in ONE list covering the whole week — unique per season slot (year +
season type + week) at the database level. It only ever chooses WITHIN the set a
rung has already made eligible, which is what stops the marquee game of the week
from sitting on the board while sixteen others are being played.

**The rank is a POSITION, not a number anyone types.**
`/admin/nfl/weeks/:slot` is a single drag-ordered column (studio-engine's
`studio/board` primitive over the vendored SortableJS, in its reorder-only
shape): drag a game up, and it is preferred over the ones below it. The visible
number is a CSS counter over the column, so it is correct the instant a drop
lands with nothing re-rendered.

**An undragged week is not a degraded one.** The list seeds in KICKOFF order,
which is exactly what the ladder does when every `focus_rank` is nil — so the
board opens showing the current behaviour rather than an empty form, and
dragging is the only way to disagree with it. An ordering also cannot hold the
same position twice, and a list that always covers the whole week cannot leave a
gap, so neither is a case anything has to police.

One write, the primitive's own contract:

| Drag | Request | Effect |
|---|---|---|
| re-sorts the list | `POST /admin/nfl/weeks/:slot/reorder` `{ slugs: [...], zone: }` | the list's order becomes `focus_rank` 1..n |

A payload that is not exactly the week's games — short, long, or naming one
twice — came from a stale page and is refused with a 422 rather than
half-applied. The write clears the slot's ranks first inside one transaction:
two games trading 1 and 2 would otherwise collide with the unique index halfway
through. Changing the order does not push to open `/live` tabs; the board picks
it up on the next score or reload.

Both halves of the board — the hero panel (`nfl_live_focus`) and the grid
(`nfl_live_scoreboard`) — are re-rendered by `Nfl::LiveBroadcast` from ONE slot
query and ONE focus decision. Refreshing one without the other is how a game
ends up drawn twice, or not at all.

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
