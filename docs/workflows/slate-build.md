# Workflow: slate-build

> **Code is law.** Every claim below cites `path/to/file.rb:NN` from the current
> codebase. Re-verify on edit — line numbers drift on refactor.
>
> **Status: PART LIVE.** Every step runs today, but split across two services and fused
> with the market ingest. The named command does not exist yet. Steps are marked ✅ LIVE
> or 🔨 PLANNED with their task.

**Trigger:** Operator command, after [[market-snapshot]], before a contest opens
**Actors:** Operator · Postgres
**Outcome:** A `Slate` holding one `SlateMatchup` per team per game, each carrying a
**frozen** `rank` and `turf_score`
**Preconditions:** Projections exist for the sport, year, and weeks requested

---

## What this SOP is for

Turn market expectations into a priced, pickable slate — and then **freeze the price**.

The build is the easy half. The freeze is the whole point.

---

## ⛔ The freeze rule — read before running this on anything live

**Never rebuild a slate whose matchups back existing Selections.**

A player picks a team at a shown multiplier. Settlement multiplies by the multiplier
**stored on the matchup row** — `app/models/selection.rb:35` (multi-week) and `:42`
(single week). Both read `slate_matchup.turf_score`. Neither recomputes.

That is not a preference. Recomputing at settlement drifted a real pick from **1.0x to
3.0x** because a projections refresh re-ranked the span after picks were locked. Payouts
settle on-chain in USDC. A player must be paid the price they were shown.

A guard exists on **both** service paths now.

**✅ The SPAN path is guarded** at `app/services/nfl/build_span_slate.rb:45`:

```ruby
return slate.reload if slate.slate_matchups.joins(:selections).exists?
```

An already-built span slate is returned **as-is**. A rebuild would `destroy_all` its
matchups (`app/services/nfl/build_span_slate.rb:109`), and `SlateMatchup has_many
:selections, dependent: :destroy` cascades that wipe into live Selections.

**✅ The WEEKLY path is now guarded too — `slate-build-split` shipped the freeze-on-pick
guard.** Step 1's `bin/rails nfl:expected_team_totals_cache` reaches `rank_slate_matchups!`
(`app/services/nfl/cache_expected_team_totals.rb:180`), which now **skips any matchup a
player has already picked** before it rewrites `rank` and `turf_score`:

```ruby
# app/services/nfl/cache_expected_team_totals.rb:192 — the money-safety guard
next if matchup.selections.exists?
# :194 — reached only for still-open matchups
matchup.update!(rank: ranking[:rank], turf_score: ranking[:turf_score])
```

The code's own comment tells the freeze story
(`app/services/nfl/cache_expected_team_totals.rb:168-179`): storing rank + `turf_score` at
ingest freezes the price against a **render** recompute, but not against a **re-ingest** — a
later rebuild (new lines, a sport flip, a correction) would re-rank the slate and overwrite
the stored score of a matchup a player has already picked. Settlement is on-chain and reads
the **stored** column (`Selection#compute_points!` never recomputes), so that overwrite
would silently re-price committed money. The guard at `:192` is what makes the price
un-repriceable after a pick: a picked matchup keeps its rank + `turf_score` exactly as
shown, and the rebuild re-ranks only the still-open matchups around it.

**One exposure remains — the SEED path, not this service.** The same rake command, run
**without `SKIP_SCHEDULE=1`**, also loads `db/seeds/nfl_2026.rb`, whose
`matchup.update!(rank:, turf_score:)` (`db/seeds/nfl_2026.rb:188`) has **no Selections
guard**. That is a reseed of the 2026 schedule, not a market rebuild — see
[[market-snapshot]], "⛔ Today, re-running this SOP can re-price a live contest", for the
site-2 detail and the season-wide pre-flight check.

Before running step 1 or [[market-snapshot]] step 3 without `SKIP_SCHEDULE=1`, check the
WHOLE SEASON, not one week. The live command takes no `WEEK` parameter and reseeds every
week its schedule covers.

**If a slate needs different numbers after it has been picked, build a new slate. Do not
refresh this one.**

---

## Sequence

### 1. Read the projections — ✅ LIVE

🔨 **PLANNED** (`slate-build-split`) — does not exist yet:

```bash
bin/rails slates:build SPORT=nfl YEAR=2026 WEEKS=3
```

✅ **LIVE** — read the freeze rule above first; this rewrites `rank` + `turf_score`
season-wide:

```bash
bin/rails nfl:expected_team_totals_cache YEAR=2026 SKIP_SCHEDULE=1
```

Today the read is a CSV parse fused into the market ingest
(`app/services/nfl/cache_expected_team_totals.rb:50`). After `slate-build-split` it reads
`team_total_projections` — the table [[market-snapshot]] owns — so a slate can be rebuilt
without re-scraping.

**⚠️ Composition seam — do not run both today.** The `slates:build` split has not landed,
so this is still the *same command* as [[market-snapshot]] step 3. If you have just run
that, **steps 1–6 of this SOP have already happened** — running it again re-executes the
whole thing. The service now freezes picked matchups
(`app/services/nfl/cache_expected_team_totals.rb:192`), but a reseed without
`SKIP_SCHEDULE=1` still re-ranks via the unguarded seed. Skip to step 7 for a span slate,
or stop here.

### 2. Ensure Games — ✅ LIVE

`app/services/nfl/cache_expected_team_totals.rb:117` (`ensure_game!`). Slug is
`<home>-vs-<away>`; venue defaults to the home team's arena; status defaults to
`scheduled`. Idempotent via `find_or_initialize_by`.

### 3. Ensure the Slate — ✅ LIVE

`app/services/nfl/cache_expected_team_totals.rb:131` (`ensure_slate!`). Names it
`NFL <year> Week <n>` and writes `week` as a real column.

**`slates` carries `sport` and `year` COLUMNS (`slates-sport-year`, DONE).** `Slate#sport`
(`app/models/slate.rb:243`) and `#season_year` (`:66`) read the column, falling back to the
name only for a row written before the migration — `sport_from_name` (`:252`) and
`year_from_name` (`:258`) are those fallback helpers, not the primary source. `ensure_slate!`
sets neither: `Slate`'s `before_validation` derives both from the name for every writer, so a
missed assignment can no longer leave a column null. Every span lookup then scopes by the
columns — `Slate.where(week:, year:, sport:)` (`app/services/nfl/build_span_slate.rb:81`),
not `name LIKE` — so a 2025 slate cannot be absorbed into a 2026 contest.

### 4. Ensure the matchups — ✅ LIVE

`app/services/nfl/cache_expected_team_totals.rb:143` (`ensure_matchups!`). Two rows per
game, one per team, each carrying that team's expected score.

The column is `slate_matchups.expected_score` — it holds NFL *points*, not goals, and
never came from DK, so it was renamed from the misnomer `dk_goals_expectation` under
`expected-score-rename` (a pure value-preserving rename; the ranking and the frozen
`turf_score` it feeds are unchanged).

### 5. Rank by TEAM — ✅ LIVE

`app/models/slate.rb:131` (`team_rankings`), reading `matchups_by_team` (`:104`).

**A team is ranked on its summed expected score across every game in the slate**, not
per row. A three-week span ranks 32 teams, not 96 rows. A one-week slate is the
degenerate case — summing one game is that game.

Tie-break is earliest kickoff, then team name (`app/models/slate.rb:138`). Do not change
it: it mirrors the per-row ordering it replaced, so a one-week slate ranks identically to
before.

**The kickoff key is the ACTIVE discriminator, not a dormant one.**
`db/seeds/nfl_2026.rb:144` and `:152` set `kickoff_at` from the schedule — measured on the
seeded 2026 season, **256 of 272** weekly-slate games carry it, and Week 3 is 16/16. Two
teams tied on expected score are separated by kickoff *before* the name is ever consulted,
so changing the key re-prices tied teams on every existing slate.

The code comment at `app/models/slate.rb:125-130` records the same measurement, so doc and
code now agree: the kickoff key is the active discriminator, not a dormant one.

### 6. Freeze the multiplier — ✅ LIVE

`app/models/slate.rb:145` calls `SlateMatchup.turf_score_for(rank, n, sport:)`
(`app/models/slate_matchup.rb:36`):

| Sport | Curve | Top |
|---|---|---|
| `nfl` | `1.0 + 1.0 * (rank-1)/(n-1)` — linear | x2.0 |
| `fifa` | `1.0 + 2.0 * ln(rank)/ln(n)` — log decay | x3.0 |

Rank 1 always prices **x1.0**; the base is pinned, not tunable
(`app/models/slate.rb:83`). The NFL curve is linear because it was measured that way:
`Nfl::PointsDistribution` computes the fit dynamically from the checked-in ESPN dataset,
and the 2023–25 snapshot is written down at `docs/FORMULAS.md:15` — linear **r² 0.9583**
(`6.76 + 31.54 * (32-rank)/31`) against log **r² 0.9184** at `docs/FORMULAS.md:14`.

The rank and score are written to **every still-open row of that team** —
`app/services/nfl/cache_expected_team_totals.rb:194` on the weekly path (skipping any picked
matchup via the `:192` guard), `app/services/nfl/build_span_slate.rb:135` on the span path.
That is the freeze: pick time and settlement read the same stored column, and once a matchup
is picked a rebuild leaves it untouched.

### 7. Span slates — ✅ LIVE (no rake task; call the service)

**There is no `slates:build` rake task.** `lib/tasks/slates.rake` defines only
`recompute_turf_scores`, and no rake task invokes `BuildSpanSlate` at all. The capability
is live — it just has no CLI of its own yet. Three ways in:

✅ **LIVE** — call the service directly:

```bash
bin/rails runner 'slate = Nfl::BuildSpanSlate.call(year: 2026, weeks: [1,2,3]); \
  puts "#{slate.name}: #{slate.slate_matchups.count} matchups"'
```

🔨 **PLANNED** (`slate-build-split`) — a wrapper for the above:

```bash
bin/rails slates:build SPORT=nfl YEAR=2026 WEEKS=1-3
```

Every **non-test** caller, for reference (a dozen more live under `test/`):

| Caller | Where |
|---|---|
| Contest creation (the real path) | `app/controllers/contests_controller.rb:1713` |
| Demo seed | `db/seeds/nfl_demo_contest.rb:51` |
| E2E seed — span 15-17 | `e2e/seed.rb:113` |
| E2E seed — span 1-3 | `e2e/seed.rb:223` |

`Nfl::BuildSpanSlate` (`app/services/nfl/build_span_slate.rb:18`) assembles one slate from
the weekly ones. It **refuses rather than truncates**: a gap in the requested weeks raises
(`:88`), because a "Weeks 1-3" sold as three weeks and scored as two is a different
contest than the operator asked for.

Sources must be single-week slates — the `reject` at `:82` filters them; `:81` is the
column scope (`week` + `year` + `sport`). Without that filter a rebuild matched the span as
its own week-1 source, wiped its rows, then copied from the now-empty slate.

---

## Data touched

**Target state**, once `slate-build-split` lands. `expected_score` is now the live
column name (renamed from `dk_goals_expectation`, see step 4); `team_total_projections`
is `nfl_team_total_projections` today.

- `games` (insert, update)
- `slates` (insert, update)
- `slate_matchups` (insert, update — `expected_score`, `rank`, `turf_score`)
- `team_total_projections` (read only)

**Not touched:** DraftKings, the network, the seed datasets. This SOP reads what
[[market-snapshot]] wrote. If a change here reaches for the network, it belongs there.

---

## Failure modes

- **Rebuilding a picked slate** — guarded on **both service paths**. The span path returns
  the existing slate untouched (`app/services/nfl/build_span_slate.rb:45`). The weekly path
  now skips any picked matchup before re-ranking — `rank_slate_matchups!` via the `next if
  matchup.selections.exists?` guard `slate-build-split` shipped
  (`app/services/nfl/cache_expected_team_totals.rb:192`), so a re-run after a projections
  refresh re-ranks only the still-open matchups. **The remaining gap is the SEED path**
  (`db/seeds/nfl_2026.rb:188`), reached by a reseed without `SKIP_SCHEDULE=1` — see
  [[market-snapshot]] site 2.
- **Missing week in a span** — raises `Nfl::BuildSpanSlate::Error`
  (`app/services/nfl/build_span_slate.rb:88`). Build the
  missing weekly slate first, then re-run.
- **Wrong-season absorption** — a 2025 slate pulled into a 2026 span. Guarded by the
  `year` + `sport` column scope (`app/services/nfl/build_span_slate.rb:81`), which
  `slates-sport-year` put in place of the old `name LIKE`.
- **Slate built but never ranked** — `team_rows` (`app/models/slate.rb:169`) falls back to
  a computed ranking when nothing is stored, so the page still renders in a sane order.
  It is a fallback, not a price: nothing settles off it.
- **Formula changed after slates were built** — `bin/rails slates:recompute_turf_scores`
  (`lib/tasks/slates.rake:3`) re-derives stored scores from each slate's sport curve,
  preserving ranks. **This re-prices picked slates.** Treat it as a settlement-affecting
  operation, not a refresh.

---

## Related workflows

- [[market-snapshot]] — the predecessor. Owns the network, the derive math, and the
  projections table this SOP reads.
- [[admin-contest-setup]] — the successor. `app/controllers/contests_controller.rb:1713` (step 7's real
  contest-creation path) is that workflow's entrypoint, so a slate built here is what a
  contest is then opened on.
