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

The guard is live at `app/services/nfl/build_span_slate.rb:44`:

```ruby
return slate.reload if slate.slate_matchups.joins(:selections).exists?
```

An already-built slate is returned **as-is**. A rebuild would `destroy_all` its matchups
(`:94`), and `SlateMatchup has_many :selections, dependent: :destroy` cascades that wipe
into live Selections.

**If a slate needs different numbers after it has been picked, build a new slate. Do not
refresh this one.**

---

## Sequence

### 1. Read the projections — ✅ LIVE

```bash
# 🔨 PLANNED name
bin/rails slates:build SPORT=nfl YEAR=2026 WEEKS=3

# ✅ what runs today — read the freeze rule above first; this rewrites rank + turf_score
bin/rails nfl:expected_team_totals_cache YEAR=2026 SKIP_SCHEDULE=1
```

Today the read is a CSV parse fused into the market ingest
(`app/services/nfl/cache_expected_team_totals.rb:43`). After `slate-build-split` it reads
`team_total_projections` — the table [[market-snapshot]] owns — so a slate can be rebuilt
without re-scraping.

### 2. Ensure Games — ✅ LIVE

`app/services/nfl/cache_expected_team_totals.rb:112` (`ensure_game!`). Slug is
`<home>-vs-<away>`; venue defaults to the home team's arena; status defaults to
`scheduled`. Idempotent via `find_or_initialize_by`.

### 3. Ensure the Slate — ✅ LIVE

`app/services/nfl/cache_expected_team_totals.rb:126` (`ensure_slate!`). Names it
`NFL <year> Week <n>` and writes `week` as a real column.

**The name is load-bearing today, and that is the bug task 1 fixes.** `slates` carries no
`sport` and no `year` column, so both are parsed out of the name: sport by regex at
`app/models/slate.rb:197`, year by regex at `:45`. Every span lookup then scopes by
`name LIKE 'NFL <year> %'` (`app/services/nfl/build_span_slate.rb:71`) to stop a 2025
slate from being absorbed into a 2026 contest. After `slates-sport-year` these become
columns and the regexes demote to backfill only.

### 4. Ensure the matchups — ✅ LIVE

`app/services/nfl/cache_expected_team_totals.rb:136` (`ensure_matchups!`). Two rows per
game, one per team, each carrying that team's expected score.

The column is `slate_matchups.dk_goals_expectation` today and becomes **`expected_score`**
under `expected-score-rename` — it holds NFL *points*, not goals, and never came from DK.
**23 files reference it** — 7 in `app/`, 12 in `test/`, 3 in `db/` (schema, migration,
seeds), 1 doc. The rename is its own task, run alone and last.

### 5. Rank by TEAM — ✅ LIVE

`app/models/slate.rb:102` (`team_rankings`), reading `matchups_by_team` (`:81`).

**A team is ranked on its summed expected score across every game in the slate**, not
per row. A three-week span ranks 32 teams, not 96 rows. A one-week slate is the
degenerate case — summing one game is that game.

Tie-break is earliest kickoff, then team name. Do not change it: it mirrors the per-row
ordering it replaced, so a one-week slate ranks identically to before. NFL games carry no
`kickoff_at`, so ties fall through to the name.

### 6. Freeze the multiplier — ✅ LIVE

`app/models/slate.rb:116` calls `SlateMatchup.turf_score_for(rank, n, sport:)`
(`app/models/slate_matchup.rb:36`):

| Sport | Curve | Top |
|---|---|---|
| `nfl` | `1.0 + 1.0 * (rank-1)/(n-1)` — linear | x2.0 |
| `fifa` | `1.0 + 2.0 * ln(rank)/ln(n)` — log decay | x3.0 |

Rank 1 always prices **x1.0**; the base is pinned, not tunable
(`app/models/slate.rb:60`). The NFL curve is linear because it was measured that way:
`Nfl::PointsDistribution` computes the fit dynamically from the checked-in ESPN dataset,
and the 2023–25 snapshot is written down at `docs/FORMULAS.md:15` — linear **r² 0.9583**
(`6.76 + 31.54 * (32-rank)/31`) against log **r² 0.9184** at `docs/FORMULAS.md:14`.

The rank and score are written to **every row of that team** —
`app/services/nfl/cache_expected_team_totals.rb:164` on the weekly path,
`app/services/nfl/build_span_slate.rb:114` on the span path. That is the freeze: pick time
and settlement read the same stored column.

### 7. Span slates — ✅ LIVE (no rake task; call the service)

**There is no `slates:build` rake task.** `lib/tasks/slates.rake` defines only
`recompute_turf_scores`, and no rake task invokes `BuildSpanSlate` at all. The capability
is live — it just has no CLI of its own yet. Three ways in:

```bash
# ✅ what runs today — call the service directly
bin/rails runner 'slate = Nfl::BuildSpanSlate.call(year: 2026, weeks: [1,2,3]); \
  puts "#{slate.name}: #{slate.slate_matchups.count} matchups"'

# 🔨 PLANNED wrapper for the above (slate-build-split)
bin/rails slates:build SPORT=nfl YEAR=2026 WEEKS=1-3
```

The two production callers, for reference:

| Caller | Where |
|---|---|
| Contest creation (the real path) | `app/controllers/contests_controller.rb:1708` |
| Demo seed | `db/seeds/nfl_demo_contest.rb:51` |

`Nfl::BuildSpanSlate` (`app/services/nfl/build_span_slate.rb:29`) assembles one slate from
the weekly ones. It **refuses rather than truncates**: a gap in the requested weeks raises
(`:78`), because a "Weeks 1-3" sold as three weeks and scored as two is a different
contest than the operator asked for.

Sources must be single-week slates — the `reject` at `:72` filters them; `:70` is the week
scope and `:71` the season scope. Without that filter a rebuild matched the span as its own
week-1 source, wiped its rows, then copied from the now-empty slate.

---

## Data touched

- `games` (insert, update)
- `slates` (insert, update)
- `slate_matchups` (insert, update — `expected_score`, `rank`, `turf_score`)
- `team_total_projections` (read only)

**Not touched:** DraftKings, the network, the seed datasets. This SOP reads what
[[market-snapshot]] wrote. If a change here reaches for the network, it belongs there.

---

## Failure modes

- **Rebuilding a picked slate** — guarded at `app/services/nfl/build_span_slate.rb:44`;
  returns the existing slate untouched. **The weekly path has no equivalent guard** —
  `ensure_matchups!` (`app/services/nfl/cache_expected_team_totals.rb:136`) updates rows in
  place, so a re-run after a projections refresh re-ranks a weekly slate that may already
  back picks. Closing that gap is the first job of `slate-build-split`.
- **Missing week in a span** — raises `Nfl::BuildSpanSlate::Error` (`:78`). Build the
  missing weekly slate first, then re-run.
- **Wrong-season absorption** — a 2025 slate pulled into a 2026 span. Guarded today by
  the `name LIKE` scope (`:71`); guarded properly by the `year` column after
  `slates-sport-year`.
- **Slate built but never ranked** — `team_rows` (`app/models/slate.rb:140`) falls back to
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
