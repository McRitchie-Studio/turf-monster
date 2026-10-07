# Live NFL Scoring

How a real touchdown becomes a number on a contest standing, what runs it, and
what it refuses to do.

> **Code is law.** Every claim below cites `path/to/file.rb:NN` from the current
> codebase, and a bare `:NN` inherits the nearest preceding path — file context
> resets at each `##` heading. The number is bookkeeping; the SYMBOL beside it is
> the claim, and `test/docs/workflow_citation_docs_test.rb` reddens when a citation
> stops landing inside the definition its prose names.
> That symbol check reaches **67 of the 96 citations** here. The other **29**
> sit in code with no enclosing definition the guard can derive, and they are not
> all checked alike. **4 of those 29** are `config/routes.rb` entries, which get a
> stricter check: each must OPEN on the line that carries its route, not merely
> quote a word found somewhere in its span. That catches most one-line drift, not
> all of it — [the workflows README](README.md) has the measurement. The rest —
> `db/schema.rb` columns and indexes, the `config/schedule.yml` header, the
> class-body callback declarations on `Goal`, class-body validations and
> constants, and ERB markup — ride the weaker LITERAL fallback: it proves the
> words the prose quotes are present in the cited lines, not that the code is.
> **All 6 citations on `bin/nfl-live-poll`** ride that fallback by construction, not by
> choice: the guard reads definitions only from `.rb`
> (with Prism) and from inline JS in `.erb`, and a script with no extension gets
> neither. One citation — the `config/schedule.yml` header — is a deliberate comment
> citation, kept because the mechanism it explains (`active_job: true`, and why
> `sidekiq-cron` cannot infer it) has no definition to point at.
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
writes `Goal` rows (`app/services/nfl/live_scores/poll_cycle.rb:633-658`) and the
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
| `Nfl::LiveScores::PollCycle#call` — one cycle | `app/services/nfl/live_scores/poll_cycle.rb:85-106` |
| `Nfl::LiveScores::PollCycle#process` — one game per scoreboard row | `:281-352` |
| `Nfl::LiveScores::PollCycle#sync_scoring_plays` — reconciles the play list | `:462-515` |
| `Game#update_scores_from_goals!` — sums points | `app/models/game.rb:67-72` |
| `Game#update_slate_matchups!` — sets `SlateMatchup#goals` | `:75-85` |
| `Game#score_affected_contests!` — re-scores open contests | `:95-107` |
| `Entry#score!` | `app/models/entry.rb:231-234` |
| `Selection#compute_points!` | `app/models/selection.rb:23-44` |
| `Contest::LiveBroadcast.goal_scored` — the per-contest live page | `app/models/contest/live_broadcast.rb:38-48` |
| `Nfl::LiveBroadcast.scoring_event` — the league board at `/live` | `app/services/nfl/live_broadcast.rb:29-46` |

## The surfaces

| What | Where |
|---|---|
| League scoreboard — `get "live", to: "live#index"` | `config/routes.rb:64` — public, read-only, no sign-in |
| Focus-game priority list — `resources :weeks` | `config/routes.rb:532-534` — admin only |
| One cycle, printed as a delta — `Nfl::LiveScores::PollCycle.call` | `bin/nfl-live-poll:110` |
| Score injectors, non-production only — `dev/live_scores#record` | `config/routes.rb:84-86` |
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

| Rung | When | Picks | Where |
|---|---|---|---|
| 1 · LIVE | a game is being played | the best-ranked one, via `Live::FocusGame.best_ranked` | `Live::FocusGame.pick` at `app/services/live/focus_game.rb:90`, definition `:111-113` |
| 2 · IMMINENT | none is, and the next kickoff is inside the lead-in | the best-ranked game in that kickoff's wave, via `Live::FocusGame.imminent` | `Live::FocusGame.pick` at `:91`, definition `:115-124` |
| 3 · HOLDOVER | neither | the game that finished most recently, via `Live::FocusGame.last_finished` | `Live::FocusGame.pick` at `:92`, definition `:126-128` |
| 4 · FALLBACK | nothing has finished either | the soonest upcoming game | `Live::FocusGame.pick` at `:93` |

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
(`db/schema.rb:430`) is a position in ONE list covering the whole week — unique per
season slot (year + season type + week) through the partial index
`index_games_on_focus_rank_per_slot` (`db/schema.rb:450`), and validated as a positive
integer on `Game` (`app/models/game.rb:46`). `Live::FocusGame.best_ranked` reads it
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
| re-sorts the list | `POST /admin/nfl/weeks/:slot/reorder` — `member { post :reorder }` (`config/routes.rb:533`) | `Admin::Nfl::WeeksController#reorder` (`app/controllers/admin/nfl/weeks_controller.rb:53-67`) makes the list's order `focus_rank` 1..n |

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
bin/nfl-live-poll --allow-settled  # override the settled-contest refusal
```

The script calls `Nfl::LiveScores::PollCycle.call` (`bin/nfl-live-poll:110`) and exits
0 when the cycle completed, whether or not anything changed — with an explicit `exit 0`
on the `--json` and `--quiet` paths (`:120`, `:123`), and by running off the end
otherwise. It reaches `exit 1` only when the scoreboard itself did not arrive — a
rescued `Nfl::Espn::Client::Error` (`:111-115`) — because then the cycle observed nothing.
**Anomalies are reported, never fatal** — a feed we do not own will have bad minutes,
and a bad minute must not end a watch.

**It is idempotent.** Every scoring event is keyed on ESPN's own play id
(`external_id`) under the unique partial index
`index_goals_on_external_id_when_present` (`db/schema.rb:471`), and
`Nfl::LiveScores::PollCycle#sync_scoring_plays` indexes what it already holds by that
id before writing (`app/services/nfl/live_scores/poll_cycle.rb:480-481`) — so a second
identical cycle writes nothing and an interrupted one resumes by being run again.

## The scheduler, and the tripwire behind it

`config/schedule.yml` — the `sidekiq-cron` job list, per its own header comment
(`config/schedule.yml:1`) — carries two NFL entries. Both are needed, and the
second exists because the first can fail silently.

| Entry | Cron | Runs | Why |
|---|---|---|---|
| `nfl_live_poll` | `*/5 * * * *` | `Nfl::LivePollJob#perform` (`app/jobs/nfl/live_poll_job.rb:47-59`) | One cycle against the slot ESPN considers current, so contests re-score with nobody watching |
| `nfl_silent_gap_check` | `37 */6 * * *` | `Nfl::SilentGapCheckJob#perform` (`app/jobs/nfl/silent_gap_check_job.rb:26-44`) | Detects a slot FINAL at the source carrying zero goals here — the failure the poller cannot report about itself |

**Both entries carry `active_job: true`**, which on Sidekiq 7 is the only signal
that works — `sidekiq-cron`'s own ActiveJob inference can never succeed, and an
entry missing the flag raises at ENQUEUE where no dashboard shows it. The
schedule's own header comment carries the mechanism (`config/schedule.yml:1`),
and `test/initializers/sidekiq_cron_schedule_test.rb` proves every entry
ENQUEUES rather than merely parsing.

**THE POLLER RUNS UNCONDITIONALLY, WITH NO GAME WINDOW, AND THAT IS THE DESIGN.**
Gating the request on "is a game on?" would cut ~288 scoreboard requests a day to
~40, and the gate would be derived from the very data the poll maintains — a
slate never built, kickoff times never refreshed, rows carrying a null season
slot. Each of those produces an empty window, so the gate closes itself,
permanently and silently, in exactly the case the poll is needed. `perform` names
no slot for the same reason (`app/jobs/nfl/live_poll_job.rb:47-59`): a bare
scoreboard request returns whatever ESPN considers current, which is more reliable
than any calendar we could keep. One request per tick covers every game in the
slot; a per-game summary is spent only when a score actually moved.

Five minutes is a FLOOR on latency, not a target. What the cron guarantees is that
a week can never again vanish because nobody ran it.

**THE TIGHT LOOP STARTS ITSELF WHILE A GAME IS ON.** After each of its cycles the
floor calls `Nfl::LiveWatchJob.ensure_running`. When a game is in progress, or
kicks off within ten minutes, that job runs one polling cycle every twenty seconds
and re-enqueues itself until nothing is left to watch. One chain runs at a time: a
cache lease holding a random token is taken at the start and renewed on every
tick, a tick holding a stale token exits without polling, and a chain that dies
simply stops renewing, so the lease lapses in ninety seconds and the next floor
tick starts a fresh one. This loop may be conditional where the floor may not,
because it is stacked on the floor rather than replacing it: a wrong gate costs
the board five-minute freshness, never a week. `NFL_LIVE_WATCH=off` stops it and
`NFL_LIVE_WATCH_SECONDS` sets the interval (never below ten seconds). The
`live-score-watch` act remains for an operator who wants to read the cycle's
changes and anomalies as they happen.

**THE PLAY-BY-PLAY RIDES THE SAME CYCLE.** Every play ESPN reports is stored as a
`GamePlay` row, keyed on ESPN's own play id, and nothing that scores ever reads
that table: a contest is paid on goals, and a play is something to watch. The
scoreboard request a cycle already makes names the most recent play of every live
game and each side's remaining timeouts, so the ordinary case costs no extra
request. A per-game summary is read for plays in two cases only: it is already in
hand because the score moved, or the game is the one the board leads with
(`Live::FocusGame`) and the scoreboard names a play not yet stored. That summary
fills in every play since the last look, with its quarter, clock and down, so the
focus game has no gaps; any other live game can miss a play when two land inside
one polling interval. The play sync runs last in a cycle, behind its own rescue,
so a summary that will not arrive is reported as `plays_fetch_failed` and costs
the score nothing.

A moved clock, down or timeout count sends five small updates per game to each
live contest's board (`Contest::LiveBroadcast.plays_changed`): the three thirds of
the rail and each team's timeout bar. A stored play adds a sixth, the play-by-play
panel, which is otherwise left alone so an open list keeps its scroll. None replaces
the focus panel, which hosts the scoring animations.

**THE FOCUS TILE'S RAIL IS THREE THIRDS AT REST.** Top: the quarter, the clock and
the down. Middle: who has the ball, and a drawn field with the ball and the line
to gain on it, away end zone left and home end zone right; `Game#ball_yard_line`
reads the position from ESPN's own yard-line label, so it needs no column of its
own. Bottom: scores, turnovers and first downs, newest first, ordered across goals
and plays by `Live::RailFeed`. A play is a first down when it was an ordinary snap
that made its distance and left the same team with the ball; the summary says so
from the play's own before-and-after, and the scoreboard's copy infers it from the
situation the play left. During a scoring takeover the rail returns to the two
halves the takeover was designed in, by one `:has()` rule in
`live/_score_animations`.

**WHY A TRIPWIRE IS THE OTHER HALF.** A cron fails exactly as quietly as no cron:
on 2026-08-25 a merge resolution dropped `active_job: true` from every entry in
this file at once and nothing ran in either environment for a day, with every
dashboard reading healthy. `Nfl::LiveScores::SilentGapCheck#unscored_final`
(`app/services/nfl/live_scores/silent_gap_check.rb:180-190`) asks the one question
that catches the whole class — is this game FINAL at the source while carrying
zero scoring events here — and `Nfl::LiveScores::SilentGapCheck#alert!` (`:206-218`)
pages a human through `ErrorLog` with the repair command in the message. It costs
nothing on a healthy week: `Nfl::LiveScores::SilentGapCheck#candidate_slots`
(`:136-143`) is one indexed query over our OWN goal-less games, so a week we have
scored produces no candidates and no network request at all. `SETTLE_GRACE` (`:51`)
keeps it off a slate still being played and `LOOKBACK` (`:63`) bounds how far back
it reaches — in a 21-day window that closes, which the constant's own comment
explains.

**THE SLOT COMES OFF THE SLATE, NOT OFF THE GAME.** `Nfl::LiveScores::SlotResolver.call`
(`app/services/nfl/live_scores/slot_resolver.rb:41-49`) answers which ESPN slot a
goal-less game belongs to, and it has to, because almost nothing fills the game's
own slot columns: `Nfl::LiveScores::PollCycle#upsert_game`
(`app/services/nfl/live_scores/poll_cycle.rb:367-403`) is their only non-test writer.
Measured on a freshly seeded database — 272 NFL games, ZERO carrying `season_year`;
256 carrying `kickoff_at`; 18 slates, all 18 resolving a year and exactly one week.
So a prefilter keyed on those columns could only ever see a slot the poller had
already polled, and reported a CONCLUSIVE CLEAN WEEK when pointed at a rebuild of
the 2026 week-2 rows. `Nfl::LiveScores::SlotResolver.weeks_for`
(`app/services/nfl/live_scores/slot_resolver.rb:100-105`) takes the week from the
matchup, then the slate's column, then the week in the slate's NAME — the last being
the only one `db/seeds/nfl_2026.rb` leaves behind.

It ALERTS and does not repair. Re-polling a historical week unattended is the one
act that can reach across the grading/settlement seam, so the decision to reach
back stays a human's — `bin/nfl-live-poll --slot Y:T:W`, which the alert names.

**THIS IS NEW AS OF 2026-09-30, AND THE HISTORY IS THE REASON FOR ALL OF IT.**
Before it, nothing in `config/schedule.yml` named the poller and
`bin/nfl-live-poll` held the only non-test call of `Nfl::LiveScores::PollCycle`
(`bin/nfl-live-poll:110`), so an operator running `live-score-watch` was the sole
path by which production contests re-scored. Nobody ran it between 2026-09-17 and 2026-09-23. Regular
season 2026 week 2 vanished: ESPN reported all 16 games Final while
turf-monster-mainnet held all 16 at `status=scheduled` with zero goals, and the
Weeks 1-3 contest — 7 active PAID entries from 7 different people — scored on two
weeks out of three for ten days. The backfill on 2026-09-27 moved the contest
total 1548.9 → 2930.3 and changed the leaderboard order. There was no error, no
anomaly and no `degraded_feed`; the standings simply omitted a week and looked
plausible.

## The anomaly vocabulary

Nine kinds. The cycle reports and continues; none is fatal.

Every kind is raised inside `Nfl::LiveScores::PollCycle`, whose file the bare `:NN`
citations below name (`app/services/nfl/live_scores/poll_cycle.rb`).

| Kind | Raised in | Means | What to do |
|---|---|---|---|
| `fetch_failed` | `#process` (`app/services/nfl/live_scores/poll_cycle.rb:344`) | One game's summary did not arrive | Ignore once. Twice on the same game: report it. |
| `unknown_team` | `#upsert_game` (`:373`) and `#record_play` (`:636`) | An abbreviation resolved to no team | **Escalate.** A team that cannot be matched silently never scores. |
| `score_drift` | `#detect_drift` (`:700-709`) | Our summed events disagree with the feed's total | Ignore a single cycle mid-play; persisting means a play was missed. |
| `degraded_feed` | `#process` (`:298`) and `#sync_scoring_plays` (`:470`, `:492`) | The feed declined to answer — an absent `scoringPlays` key, zero plays against goals we hold, or a blank score on a live game | The cycle **refuses to act**. Investigate if it persists. |
| `status_regression` | `#status_for` (`:441`) | A stale row reported an earlier state for a completed game | Informational; the game keeps its completed status. |
| `recap_push_failed` | `#push_recap` (`:685-694`) | The studio hub could not be told a game finished | Informational. The game IS settled; only the content idea is missing. |
| `unsettled_final` | `#process` (`:320`) | The feed says FINAL but our events disagree with its total | The game is **not settled**. It settles on the next reconciling cycle. |
| `cycle_error` | `#process` (`:351`) | An unexpected exception, captured to `ErrorLog` | A bug. Read the ErrorLog. |
| `settled_contest` | `#refusal` (`:236-245`) | EVERY contest on this ONE game's slate is settled, so this game was skipped. The rest of the slot still ran | Expected on a finished week. Override deliberately with `bin/nfl-live-poll --allow-settled`. |
| `settled_contest_coscored` | `#coscored` (`:224-232`) | This game WAS scored for an open contest on its slate, and a settled contest shares that slate, so its matchup goals moved too | Informational, and the trade is deliberate — see "It will not re-score a SETTLED contest" below. The settled contest's own entry scores, ranks and payouts were not recomputed. |

## What it refuses to do

These are guards with reproductions behind them, not defensive padding.

- **It will not wipe scores on a degraded response.** A 200 with valid JSON and
  no `scoringPlays` key once deleted every goal a game held — 3 to 0, 10-7 to
  0-0 — silently, because a blank scoreboard score also parsed to 0 and the
  drift check then compared two zeros and agreed. `Nfl::Espn::ScoringPlays.reported?`
  now separates "no plays" from "no answer" by asking whether `scoringPlays` is an
  Array at all (`app/services/nfl/espn/scoring_plays.rb:65-67`);
  `Nfl::LiveScores::PollCycle#sync_scoring_plays` refuses to sweep to nothing
  (`app/services/nfl/live_scores/poll_cycle.rb:470`, `:492`); and `#process` treats a
  blank score on a live game as an anomaly rather than a zero (`:298`).
- **It will not settle a game it cannot reconcile.** Finalising flips every
  matchup and re-scores every contest. Doing that while our events disagree with
  the feed settles a contest on a number one side of the system does not
  believe, so the game stays open and the disagreement is reported.
- **It will not re-score a SETTLED contest.** The cycle is idempotent about
  scoring EVENTS — plays are keyed on ESPN's play id under
  `index_goals_on_external_id_when_present` — but not about their consequences: one
  new or withdrawn play re-sums the game and rewrites every `SlateMatchup#goals` it
  feeds. Under a contest whose ranks and payouts are final that leaves a
  leaderboard disagreeing with the money paid out, and `Contest#grade!`
  (`app/models/contest.rb:476-517`) raises rather than regrade it.
  `Nfl::LiveScores::PollCycle#settled_verdicts`
  (`app/services/nfl/live_scores/poll_cycle.rb:175-200`) answers before any write,
  and `Nfl::LiveScores::PollCycle#slate_ids_for` (`:209-217`) asks from the union of
  the games we hold and the slugs the feed rows would take — a `SlateMatchup` can name
  a slug before any `Game` row exists for it.
  `Nfl::LiveScores::PollCycle#refusal` (`:236-245`) reports the skip as an anomaly.

  **THE DECISION IS PER GAME, AND IT IS MADE FROM THE CONTEST POPULATION.** A slate
  carries SEVERAL contests (`has_many :contests`, `app/models/slate.rb:13`) and
  `contests.slate_id` is not unique — so deciding this once per cycle let one graded
  tier stop every game on the slot from being written, which re-created the original
  incident for the open tier beside it. The rule is now: a game is skipped only when
  EVERY contest that renders it is settled. A settled tier sharing a slate with an
  OPEN one does not stop the cycle, because the two tiers share their `SlateMatchup`
  rows and one row cannot be both frozen and current — refusing would leave the live
  paid contest scoring short forever, which is strictly the larger harm. What the
  settled tier's money stands on does not move either way:
  `Game#score_affected_contests!` (`app/models/game.rb:95-107`) scopes to
  `status: [:open]`, so its stored score — written by `Entry#score!`
  (`app/models/entry.rb:231-234`) — and its `Selection#points` are never recomputed.
  `Nfl::LiveScores::PollCycle#coscored`
  (`app/services/nfl/live_scores/poll_cycle.rb:224-232`) reports that case, so the
  trade is visible in the watch log rather than silent.

  It reads `Contest#status`, never `onchain_settled`: `grade!` queues the
  settle transaction through `Contest#settle_onchain!` and then writes `settled`
  (`app/models/contest.rb:791-793`), so a graded, paid-out contest routinely reads
  `onchain_settled` false.
- **It will not un-complete a finished game.** A stale scoreboard row would
  otherwise re-open a settled game and re-fire the FINAL broadcast.
- **It will not store an id-less play.** `play["id"].to_s` yields `""`, which the
  unique index `index_goals_on_external_id_when_present` covers with its
  `WHERE external_id IS NOT NULL` predicate (`db/schema.rb:471`) — so a second id-less
  play anywhere in the league would collide across games.

## The studio recap push

When a game SETTLES, the cycle enqueues `Studio::GameRecapPushJob`, which posts
the final to the McRitchie Studio hub. The hub turns it into a content idea
("Bills Beat Dolphins 24-17") at the head of the faceless social pipeline.

**It is the least important thing a finalisation does, and it is built that way.**
By the time it runs the game is already settled and every open contest has
already re-scored. So it may fail freely: a hub that is down, a Redis that will
not take the enqueue, or a secret that was never set must not cost a contest its
settlement or end a twelve-hour watch. Failures become a `recap_push_failed`
anomaly — reported, never fatal.

It ENQUEUES rather than calling. An HTTP round trip to another host has no
business inside the loop that re-scores contests people paid to enter; the worker
dyno pays that cost.

**Configuration.** `AGENT_API_SECRET` is the hub's shared agent secret and is
what arms the push — with it absent the push is skipped SILENTLY, so a laptop or
a review app scores exactly as it always did. `STUDIO_API_BASE` overrides the
hub URL (default `https://mcritchie.studio`). The hub endpoint is idempotent, so
a Sidekiq retry that already succeeded answers 200 and changes nothing.

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

<!-- citation-guard: enforced -->
