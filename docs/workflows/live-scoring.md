# Live NFL Scoring

How a real touchdown becomes a number on a contest standing, what runs it, and
what it refuses to do.

> **Code is law.** Every claim below cites `path/to/file.rb:NN` from the current
> codebase, and a bare `:NN` inherits the nearest preceding path — file context
> resets at each `##` heading. The number is bookkeeping; the SYMBOL beside it is
> the claim, and `test/docs/workflow_citation_docs_test.rb` reddens when a citation
> stops landing inside the definition its prose names.
> That symbol check reaches **47 of the 72 citations** here. The other **25**
> sit in code with no enclosing definition the guard can derive: `config/routes.rb`
> entries, `db/schema.rb` columns and indexes, the `config/schedule.yml` header,
> the class-body callback declarations on `Goal`, class-body validations and
> constants, and ERB markup. Those ride the weaker LITERAL fallback: it proves the
> words the prose quotes are present in the cited lines, not that the code is.
> **All 6 citations on `bin/nfl-live-poll`** are in that 25 by construction, not by
> choice: the guard reads definitions only from `.rb`
> (with Prism) and from inline JS in `.erb`, and a script with no extension gets
> neither. One citation — the `config/schedule.yml` header — is a deliberate comment
> citation; an ABSENCE ("no NFL entry") cannot be cited, only grepped.
>
> **Cited since 2026-09-09.** Until then this document named its symbols and pointed
> at none of them, which made it invisible to the guard rather than weakly checked.

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

Nothing in the poller writes a score directly. `Nfl::LiveScores::PollCycle#record_play`
writes `Goal` rows (`app/services/nfl/live_scores/poll_cycle.rb:377-402`) and the
existing callbacks carry them the rest of the way, which is why a hand-recorded goal
and a fed one behave identically. On `Goal`, the `after_create :refresh_game_scores`
declaration (`app/models/goal.rb:46`) runs `Goal#refresh_game_scores` (`:156-158`),
which starts the recompute chain below; the two `after_create_commit` hooks that call
`Contest::LiveBroadcast.goal_scored` and `Nfl::LiveBroadcast.scoring_event` fire only
once that recompute has committed (`:60-61`). An amended play — ESPN restates a
touchdown as 6 then 7 once the kick is good — re-runs the same recompute through
`after_update :refresh_game_scores` (`:55`) and redraws via `score_changed` instead of
announcing a second score (`:68-70`).

Every link in that chain, with its owner:

| Step | Where |
|---|---|
| `Nfl::LiveScores::PollCycle#call` — one cycle | `app/services/nfl/live_scores/poll_cycle.rb:74-86` |
| `Nfl::LiveScores::PollCycle#process` — one game per scoreboard row | `:110-176` |
| `Nfl::LiveScores::PollCycle#sync_scoring_plays` — reconciles the play list | `:290-343` |
| `Game#update_scores_from_goals!` — sums points | `app/models/game.rb:66-71` |
| `Game#update_slate_matchups!` — sets `SlateMatchup#goals` | `:74-84` |
| `Game#score_affected_contests!` — re-scores open contests | `:94-106` |
| `Entry#score!` | `app/models/entry.rb:211-214` |
| `Selection#compute_points!` | `app/models/selection.rb:23-44` |
| `Contest::LiveBroadcast.goal_scored` — the per-contest live page | `app/models/contest/live_broadcast.rb:34-44` |
| `Nfl::LiveBroadcast.scoring_event` — the league board at `/live` | `app/services/nfl/live_broadcast.rb:29-46` |

## The surfaces

| What | Where |
|---|---|
| League scoreboard — `get "live", to: "live#index"` | `config/routes.rb:62` — public, read-only, no sign-in |
| Focus-game priority list — `resources :weeks` | `config/routes.rb:493-495` — admin only |
| One cycle, printed as a delta — `Nfl::LiveScores::PollCycle.call` | `bin/nfl-live-poll:80` |
| Score injectors, non-production only — `dev/live_scores#record` | `config/routes.rb:76-78` |
| The operator act | `live-score-watch` (mcritchie-studio SOP, Avi) |

## The focus game

`/live` leads with ONE game, drawn full width above the grid, and that game is
not also drawn in the grid — the board shows every game exactly once. Pressing
any card hands the panel over to it, takes it out of the grid, and scrolls the
page up to it. After first paint the choice is the reader's: it is Alpine state
from the `nflLiveBoard` factory (`app/views/live/index.html.erb:18`) declared on the
page wrapper (`:51`), outside both broadcast targets, so a score cannot reset it.

Which game the board OPENS on is decided by `Live::FocusGame.pick`
(`app/services/live/focus_game.rb:82-94`) — a ladder over the week's games, first
rung that answers wins. `Live::FocusGame.call` (`:77-79`) is the thin wrapper the
views use, returning the slug:

| Rung | When | Picks | Where, inside `Live::FocusGame.pick` |
|---|---|---|---|
| 1 · LIVE | a game is being played | the best-ranked one, via `Live::FocusGame.best_ranked` | `app/services/live/focus_game.rb:90`, definition `:111-113` |
| 2 · IMMINENT | none is, and the next kickoff is inside the lead-in | the best-ranked game in that kickoff's wave, via `Live::FocusGame.imminent` | `:91`, definition `:115-124` |
| 3 · HOLDOVER | neither | the game that finished most recently, via `Live::FocusGame.last_finished` | `:92`, definition `:126-128` |
| 4 · FALLBACK | nothing has finished either | the soonest upcoming game | `:93` |

"Being played" is `Live::FocusGame.phase` (`:104-109`), which counts a PASSED KICKOFF
as started — the poller flips `status` on its own cycle, so a board keyed on `status`
alone would answer "nothing is on" while the ball is in the air.

Two constants tune it per sport — the `POLICIES` hash
(`app/services/live/focus_game.rb:60-63`), read through `Live::FocusGame.policy_for`
(`:138-145`) — giving the NFL a **12-hour lead-in** and a **90-minute wave**. Between them they produce the
league's actual rhythm without a line of calendar arithmetic: Tuesday to
Thursday the board leads with Thursday night (rung 4); Sunday morning the wave
narrows the field to the one o'clock kickoffs so a rank-1 night game cannot own
breakfast (rung 2); through the afternoon the best rank among the games actually
being played leads and moves on as each finishes (rung 1); Sunday night football
holds the board overnight (rung 3) and Monday night football takes it at 8:15
Monday morning, twelve hours before its kickoff (rung 2).

**The order is a tiebreak, never an override.** The `focus_rank` column on `games`
(`db/schema.rb:317`) is a position in ONE list covering the whole week — unique per
season slot (year + season type + week) through the partial index
`index_games_on_focus_rank_per_slot` (`db/schema.rb:336`), and validated as a positive
integer on `Game` (`app/models/game.rb:45`). `Live::FocusGame.best_ranked` reads it
(`app/services/live/focus_game.rb:112`) only WITHIN the set a rung has already made
eligible, which is what stops the marquee game of the week from sitting on the board
while sixteen others are being played.

**The rank is a POSITION, not a number anyone types.**
`/admin/nfl/weeks/:slot` — `Admin::Nfl::WeeksController#show`
(`app/controllers/admin/nfl/weeks_controller.rb:39-45`) — is a single drag-ordered
column rendered by studio-engine's `studio/board/board` primitive over the vendored
SortableJS, in its reorder-only shape (`app/views/admin/nfl/weeks/show.html.erb:74-84`):
drag a game up, and it is preferred over the ones below it. The visible number is a CSS
counter over the column, so it is correct the instant a drop lands with nothing
re-rendered.

**An undragged week is not a degraded one.** The list seeds in KICKOFF order,
which is exactly what the ladder does when every `focus_rank` is nil — so the
board opens showing the current behaviour rather than an empty form, and
dragging is the only way to disagree with it. An ordering also cannot hold the
same position twice, and a list that always covers the whole week cannot leave a
gap, so neither is a case anything has to police.

One write, the primitive's own contract:

| Drag | Request | Effect |
|---|---|---|
| re-sorts the list | `POST /admin/nfl/weeks/:slot/reorder` — `member { post :reorder }` (`config/routes.rb:493-495`) | `Admin::Nfl::WeeksController#reorder` (`app/controllers/admin/nfl/weeks_controller.rb:53-67`) makes the list's order `focus_rank` 1..n |

A payload that is not exactly the week's games — short, long, or naming one twice —
came from a stale page, and `Admin::Nfl::WeeksController#reorder` refuses it with a 422
rather than half-applying it (`app/controllers/admin/nfl/weeks_controller.rb:60-63`).
`Admin::Nfl::WeeksController#write_order!` (`:76-83`) clears the slot's ranks first
inside one transaction (`:78`): two games trading 1 and 2 would otherwise collide with
the unique index halfway through. Changing the order does not push to open `/live` tabs; the board picks
it up on the next score or reload.

Both halves of the board — the hero panel and the grid — are re-rendered by
`Nfl::LiveBroadcast.replace_board` (`app/services/nfl/live_broadcast.rb:84-102`) from
ONE slot query, `Nfl::LiveBroadcast.slot_games` (`:61-65`), and ONE focus decision.
Refreshing one without the other is how a game ends up drawn twice, or not at all.

## `bin/nfl-live-poll`

```bash
bin/nfl-live-poll                  # the slot ESPN considers current
bin/nfl-live-poll --slot 2026:1:4  # year:season_type:week  (1=pre 2=reg 3=post)
bin/nfl-live-poll --json           # machine-readable
bin/nfl-live-poll --quiet          # print nothing when nothing changed
```

The script calls `Nfl::LiveScores::PollCycle.call` (`bin/nfl-live-poll:80`) and exits
0 when the cycle completed, whether or not anything changed — with an explicit `exit 0`
on the `--json` and `--quiet` paths (`:90`, `:93`), and by running off the end
otherwise. It reaches `exit 1` only when the scoreboard itself did not arrive — a
rescued `Nfl::Espn::Client::Error` (`:81-85`) — because then the cycle observed nothing.
**Anomalies are reported, never fatal** — a feed we do not own will have bad minutes,
and a bad minute must not end a watch.

**It is idempotent.** Every scoring event is keyed on ESPN's own play id
(`external_id`) under the unique partial index
`index_goals_on_external_id_when_present` (`db/schema.rb:357`), and
`Nfl::LiveScores::PollCycle#sync_scoring_plays` indexes what it already holds by that
id before writing (`app/services/nfl/live_scores/poll_cycle.rb:308-309`) — so a second
identical cycle writes nothing and an interrupted one resumes by being run again.

## THERE IS NO SCHEDULER

`config/schedule.yml` — the `sidekiq-cron` job list, per its own header comment
(`config/schedule.yml:1`) — has no NFL entry: nothing in it names the poller, and `bin/nfl-live-poll`
is the only non-test caller of `Nfl::LiveScores::PollCycle` (`bin/nfl-live-poll:80`). **An operator running the
`live-score-watch` act is the sole path by which production contests re-score.**

That is a deliberate current state, not an oversight — but it means the act's
target matters enormously, and the SOP makes the environment explicit in every
command for that reason. If this ever moves to a cron trigger, the SOP's own
design note is the place to start.

## The anomaly vocabulary

Seven kinds. The cycle reports and continues; none is fatal.

Every kind is raised inside `Nfl::LiveScores::PollCycle`, whose file the bare `:NN`
citations below name (`app/services/nfl/live_scores/poll_cycle.rb`).

| Kind | Raised in | Means | What to do |
|---|---|---|---|
| `fetch_failed` | `#process` (`app/services/nfl/live_scores/poll_cycle.rb:168`) | One game's summary did not arrive | Ignore once. Twice on the same game: report it. |
| `unknown_team` | `#upsert_game` (`:197`) and `#record_play` (`:380`) | An abbreviation resolved to no team | **Escalate.** A team that cannot be matched silently never scores. |
| `score_drift` | `#detect_drift` (`:417-426`) | Our summed events disagree with the feed's total | Ignore a single cycle mid-play; persisting means a play was missed. |
| `degraded_feed` | `#process` (`:127-128`) and `#sync_scoring_plays` (`:298`, `:320`) | The feed declined to answer — an absent `scoringPlays` key, zero plays against goals we hold, or a blank score on a live game | The cycle **refuses to act**. Investigate if it persists. |
| `status_regression` | `#status_for` (`:266`) | A stale row reported an earlier state for a completed game | Informational; the game keeps its completed status. |
| `unsettled_final` | `#process` (`:149`) | The feed says FINAL but our events disagree with its total | The game is **not settled**. It settles on the next reconciling cycle. |
| `cycle_error` | `#process` (`:175`) | An unexpected exception, captured to `ErrorLog` | A bug. Read the ErrorLog. |

## What it refuses to do

These are guards with reproductions behind them, not defensive padding.

- **It will not wipe scores on a degraded response.** A 200 with valid JSON and
  no `scoringPlays` key once deleted every goal a game held — 3 to 0, 10-7 to
  0-0 — silently, because a blank scoreboard score also parsed to 0 and the
  drift check then compared two zeros and agreed. `Nfl::Espn::ScoringPlays.reported?`
  now separates "no plays" from "no answer" by asking whether `scoringPlays` is an
  Array at all (`app/services/nfl/espn/scoring_plays.rb:65-67`);
  `Nfl::LiveScores::PollCycle#sync_scoring_plays` refuses to sweep to nothing
  (`app/services/nfl/live_scores/poll_cycle.rb:298`, `:320`); and `#process` treats a
  blank score on a live game as an anomaly rather than a zero (`:127-128`).
- **It will not settle a game it cannot reconcile.** Finalising flips every
  matchup and re-scores every contest. Doing that while our events disagree with
  the feed settles a contest on a number one side of the system does not
  believe, so the game stays open and the disagreement is reported.
- **It will not un-complete a finished game.** A stale scoreboard row would
  otherwise re-open a settled game and re-fire the FINAL broadcast.
- **It will not store an id-less play.** `play["id"].to_s` yields `""`, which the
  unique index `index_goals_on_external_id_when_present` covers with its
  `WHERE external_id IS NOT NULL` predicate (`db/schema.rb:357`) — so a second id-less
  play anywhere in the league would collide across games.

## The external dependency

ESPN's public scoreboard and summary endpoints. No key, no account, no contract.

**It refuses Ruby.** Measured against the live endpoint: no `User-Agent` → 403;
a custom `TurfMonster/1.0` → 403; a Chrome string sent from Ruby → 403;
`curl/8.7.1` → 200. The `USER_AGENT` constant carries an accepted agent
(`app/services/nfl/espn/client.rb:41`) and `Nfl::Espn::Client#perform` sends it on
every request (`:106`); `test/services/nfl/espn/client_test.rb` asserts it — the same gap once left
`Nfl::FetchHistoricalScores` broken in main, because its only test covered the
pure parse seam and could not see a transport failure.

Treat the feed as unowned: undocumented, unversioned, and free to change. That
is also why it should not be the last word on a settled contest.
