# Workflow: market-snapshot

> **Code is law.** Every claim below cites `path/to/file.rb:NN` from the current
> codebase. Re-verify on edit — line numbers drift on refactor.
>
> **Status: PART LIVE.** The derive math and the ingest half run today. The DraftKings
> fetch runs for soccer only, and the snapshot artifact does not exist yet. Every step
> below is marked ✅ LIVE or 🔨 PLANNED with its task. Do not read a 🔨 step as
> something you can run now.

**Trigger:** Operator command, weekly per sport — before [[slate-build]]
**Actors:** Operator · DraftKings sportsbook (public web) · Postgres
**Outcome:** A seed-format dataset on disk, a `MarketSnapshot` artifact row, and one
`TeamTotalProjection` per team per game
**Preconditions:** `Team` rows seeded for the sport; the week's games are posted on DK

---

## What this SOP is for

Capture what the betting market expects each team to score, and write it down in a form
that survives a database reset and travels between environments.

It ends at a file plus rows. It never creates a Slate, never ranks anything, and never
prices a pick. That is [[slate-build]]'s job, and the split is the point: a market
refresh must never silently re-price a contest a player already entered.

---

## The two bases — posted beats derived

DraftKings posts team totals directly only when a game is close, and only for games it
prices deeply. The rest of the year it posts the primitives: a **game total** and a
**spread**. This SOP works in both regimes and records which one it got.

| Basis | When | Source |
|---|---|---|
| `posted` | DK lists a team-total O/U for the team | DK's own number, used as-is |
| `derived` | Only game total + spread are posted | Computed from the primitives |

**Prefer `posted`. Fall back to `derived`. Never mix silently — always stamp `basis`.**

The derive math is live today in `Nfl::CacheExpectedTeamTotals.derive`
(`app/services/nfl/cache_expected_team_totals.rb:22` is the `def`; the arithmetic is at
`:25` and `:29`). Paraphrased below for readability — the real locals are `total` and
`spread`:

```ruby
home_points = ((game_total - home_spread) / 2).round(2)
away_points = (game_total - home_points).round(2)
```

The away side is `total - home`, not `(total + spread) / 2`. Both are algebraically the
same; only the first guarantees the two sides sum to exactly the game total after
rounding.

Sign convention, resolved at `app/services/nfl/cache_expected_team_totals.rb:210`
(`home_spread_for`): **the favorite's spread is negative.** When the home team is the
favorite, `home_spread` is that negative number. When the away team is the favorite,
`home_spread` is its absolute value. A row whose `favorite_team_slug` matches neither
side falls through to `0`.

**Re-running upgrades a week's projections in place.** A Week 3 snapshot taken in July is
`derived`; the same command on the Thursday of Week 3 overwrites it with `posted`. When
both exist, keep both — the gap between DK's posted number and your derived one is the
accuracy check on the formula above.

---

## ⛔ Today, re-running this SOP can re-price a live contest

**This warning belongs here, not only in [[slate-build]], because the dangerous command is
in THIS file** (step 3).

Until `slate-build-split` lands, the ✅ LIVE command `nfl:expected_team_totals_cache` does
not stop at projections. It also creates Slates and rewrites **`rank` and `turf_score` on
every matchup**, unconditionally:

```ruby
# app/services/nfl/cache_expected_team_totals.rb:172 — no guard of any kind
matchup.update!(rank: ranking[:rank], turf_score: ranking[:turf_score])
```

`Nfl::BuildSpanSlate` refuses to rebuild a slate backing live Selections
(`app/services/nfl/build_span_slate.rb:44`). **The weekly path has no equivalent guard.**
Settlement
multiplies by the stored `turf_score` (`app/models/selection.rb:35`, `:42`), so re-running
this command against a week whose slate already backs picks re-prices those picks after
they were locked — and payouts settle on-chain.

**Before running step 3 against a week that may already be picked**, check first:

```bash
bin/rails runner 'slate = Slate.find_by(name: "NFL 2026 Week 3"); \
  puts slate && slate.slate_matchups.joins(:selections).exists? ? "HAS PICKS — do not re-run" : "safe"'
```

Full rule and rationale: [[slate-build]], "The freeze rule".

---

## Sequence

### 1. Fetch — 🔨 PLANNED (`market-snapshot-impl`)

```bash
npm run market-snapshot -- --sport nfl --week 3
```

Drives a headless browser against the DK sportsbook and writes the dataset. Network
lives here and nowhere else.

**Today:** `scripts/scrape_draftkings.js` does this shape for soccer only. It is hard-wired
to a World Cup URL (`scripts/scrape_draftkings.js:22`), carries a 60-country name map
(`scripts/scrape_draftkings.js:25`), and picks the O/U line whose over-odds sit closest to
even money (`scripts/scrape_draftkings.js:146`). Sport, league, and week must become
parameters. Run it today with `npm run scrape` / `npm run scrape:headed` (`package.json`).

**Preconditions for the scraper** — it needs a browser installed, and `package.json`
declares only `@playwright/test` while `scripts/scrape_draftkings.js:14` requires the
`playwright` package itself:

```bash
npm install
npx playwright install chromium
```

Run it from the **primary checkout** (`/Users/alex/projects/turf-monster`). A fresh
worktree has no `node_modules`, so the `require("playwright")` fails there.

**Pattern to copy:** `Nfl::FetchHistoricalScores` (`app/services/nfl/fetch_historical_scores.rb:9`)
already models fetch-to-checked-in-dataset correctly — network only on the rake task, a
pure parse seam at `:26` that turns a payload into rows and is total over empty input.

### 2. Write the dataset — 🔨 PLANNED (`market-snapshot-impl`)

Output path: `db/seeds/data/<sport>/<year>-w<NN>-team-totals.csv`

Seed format is deliberate: a plain checked-in file is what carries this data into QA and
production without a database dump.

Columns — extending the live header at `db/seeds/data/nfl/2026_expected_team_totals.csv`:

| Column | Notes |
|---|---|
| `week`, `away_team_slug`, `home_team_slug` | ✅ live today |
| `favorite_team_slug`, `favorite_spread`, `game_total` | ✅ live today — the primitives |
| `source`, `source_published_on`, `source_url`, `source_text` | ✅ live today — provenance |
| `basis` | 🔨 `posted` or `derived` |
| `posted_line`, `over_odds`, `under_odds` | 🔨 DK's own number, blank when unposted |

**⚠️ Today's NFL numbers did not come from DraftKings.** The checked-in
`db/seeds/data/nfl/2026_expected_team_totals.csv` was **hand-transcribed from a Yahoo
article** — its `source` column reads `yahoo_sports_2026_lookahead`, with the article URL
in `source_url` and the quoted line in `source_text`. Every row is `derived`; none is
`posted`.

So until step 1 ships, **today's actual refresh procedure is manual**: edit or replace the
CSV by hand, keep the `source*` columns honest, then run step 3 with
`CSV_PATH=/path/to/your.csv`. There is no NFL scraper to run.

### 3. Ingest — ✅ LIVE (as `nfl:expected_team_totals_cache`)

```bash
# 🔨 PLANNED name
bin/rails market:snapshot SPORT=nfl WEEK=3

# ✅ what runs today — read the ⛔ warning above before running this
bin/rails nfl:expected_team_totals_cache YEAR=2026 SKIP_SCHEDULE=1
bin/rails nfl:expected_team_totals_cache YEAR=2026 CSV_PATH=/path/to/refreshed.csv
```

Reads the dataset, derives where needed, and upserts one row per team per game.

**`SKIP_SCHEDULE=1` is the lever that makes today's command behave like the pure ingest
this SOP describes.** Without it, `lib/tasks/nfl.rake:6` also loads
`db/seeds/nfl_2026.rb` — the whole season schedule — before ingesting. `CSV_PATH`
(`nfl.rake:5`) points it at a refreshed line sheet instead of the checked-in default.

**Even with `SKIP_SCHEDULE=1`, this task does far more than ingest.**
`Nfl::CacheExpectedTeamTotals#call` (`app/services/nfl/cache_expected_team_totals.rb:43`)
creates Games (`:112`), creates Slates (`:126`), and creates SlateMatchups and ranks them
(`:136`, `:164`). Those four belong to [[slate-build]] and move there under
`slate-build-split`.

**Idempotency — correct today, but its grain changes under the split.**
`upsert_projection!` (`app/services/nfl/cache_expected_team_totals.rb:176`) keys on
`(year, week, game_slug, team_slug)`, which is already per-week and needs no change.
`delete_stale_rows` (`:204`) is the problem: it
scopes to `where(year: @year)` and deletes every row the current run did not touch. That
is right today, when one run ingests the **whole season** from one CSV.

⚠️ **The split makes the run per-week** (`market:snapshot … WEEK=3`, one
`<year>-w<NN>-team-totals.csv`). A year-scoped sweep after a single-week run would delete
weeks 1–2. `slate-build-split` must re-scope the sweep to `(year, week)` — do not carry
`delete_stale_rows` across unchanged.

### 4. Record the artifact — 🔨 PLANNED (`market-snapshot-impl`)

One `MarketSnapshot` row per run — the historical record of the process having been run:

| Column | Purpose |
|---|---|
| `sport`, `year`, `week` | what was captured |
| `source`, `source_url`, `captured_at` | where it came from, when |
| `dataset_path`, `checksum` | which seed file it wrote |
| `row_count`, `posted_count`, `derived_count` | how much, and by which basis |

Every projection `belongs_to :market_snapshot`. This replaces the debug PNGs in
`scripts/data/` (3.5 MB of committed screenshots) as the record of what ran.

---

## Data touched

**Target state**, once `slate-build-split` lands:

- `team_total_projections` (upsert, delete stale) — today `nfl_team_total_projections`
- `market_snapshots` (insert) — 🔨 planned
- `db/seeds/data/<sport>/*.csv` (write)
- external: DraftKings sportsbook over HTTPS, browser-driven

**Today the ✅ LIVE command in step 3 writes far more than that.**
`nfl:expected_team_totals_cache` also writes:

- `games` (insert, update) — `app/services/nfl/cache_expected_team_totals.rb:112`
- `slates` (insert, update) — `app/services/nfl/cache_expected_team_totals.rb:126`
- `slate_matchups` (insert, update — including **`rank` and `turf_score`**) —
  `app/services/nfl/cache_expected_team_totals.rb:136` and `:164`

Only `selections` and `contests` are genuinely untouched, and even those are reached
indirectly: a rewritten `turf_score` is what settlement multiplies by.

Once the split lands, this SOP touches only the first list. Until then, treat step 3 as a
[[slate-build]] operation wearing an ingest's name.

---

## Failure modes

- **DK posts no team totals for the week** — expected for most of the year. Fall back to
  `derived` from game total + spread and stamp `basis`. Not an error.
- **DK posts neither team totals nor a spread** — refuse the week. A snapshot with no
  market input is worse than no snapshot, because [[slate-build]] would price a contest
  off it. Fail loudly and leave the previous dataset in place.
- **Team name does not resolve to a slug** — today the soccer scraper logs
  `? Unknown team` and skips the row (`scripts/scrape_draftkings.js:112`). A skipped row
  silently shortens the slate. Count skips, print them, and fail the run when any team in
  the week is unresolved.
- **DK markup changes** — the scraper parses `document.body.innerText`
  (`scripts/scrape_draftkings.js:71`), so a layout change yields zero rows rather than an
  exception. Assert a minimum row count for the week before writing the dataset.
- **Stale rows from a shrinking week** — handled *today* by `delete_stale_rows`
  (`app/services/nfl/cache_expected_team_totals.rb:204`), which removes untouched rows for
  the whole **year**. Correct while one run ingests the whole season; **destructive once
  the run is per-week** — see the grain warning in step 3.
- **Re-running against an already-picked week** — see the ⛔ warning above. Today's LIVE
  command rewrites `rank` and `turf_score` with no live-Selections guard.

---

## Related workflows

- [[slate-build]] — the successor. Reads what this SOP writes, and owns everything
  from Slate creation through the frozen multiplier.
