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
**Outcome:** A seed-format dataset on disk, plus one projection row per team per game.
(🔨 Target-state names: the `MarketSnapshot` artifact does not exist yet, and the
projection table is `nfl_team_total_projections` today.)
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

Sign convention, resolved at `app/services/nfl/cache_expected_team_totals.rb:240`
(`home_spread_for`): **the favorite's spread is negative.** When the home team is the
favorite, `home_spread` is that negative number. When the away team is the favorite,
`home_spread` is its absolute value. A row whose `favorite_team_slug` matches neither
side falls through to `0`.

**Re-running upgrades a week's projections in place.** A Week 3 snapshot taken in July is
`derived`; the same command on the Thursday of Week 3 overwrites it with `posted`. It is a
genuine overwrite, not an accumulation: the upsert key is one row per
`(year, week, game_slug, team_slug)`
(`app/services/nfl/cache_expected_team_totals.rb:199`), so a week holds exactly one
projection per team and the derived value is gone once posted lands.

🔨 **PLANNED (`market-snapshot-impl`):** keep the posted line alongside the derived one
(the `posted_line` column in step 2) so the gap between DK's number and ours becomes a
standing accuracy check on the formula above. That comparison is not possible today.

---

## ⛔ Today, re-running this SOP can re-price a live contest

**This warning belongs here, not only in [[slate-build]], because the dangerous command is
in THIS file** (step 3).

`slate-build-split` (#263) closed the ingest service's own re-rank, so the ✅ LIVE command
`nfl:expected_team_totals_cache` now rewrites **`rank` and `turf_score`** from **one guarded
site and one still-unguarded one**. The still-open one — the schedule seed — is the nastier
one.

**Site 1 — the ingest's own re-rank — ✅ NOW GUARDED (`slate-build-split`, #263).**
`rank_slate_matchups!` (`app/services/nfl/cache_expected_team_totals.rb:192`) skips any
matchup a player has already picked before it rewrites the row:

```ruby
next if matchup.selections.exists?                                       # :192 — the guard
matchup.update!(rank: ranking[:rank], turf_score: ranking[:turf_score])  # :194
```

It re-ranks by summed expected score, so an unguarded re-run would have yielded *stale*
prices on picked matchups. The guard now freezes those and re-ranks only the still-open ones.

**Site 2 — the schedule seed** (`db/seeds/nfl_2026.rb:186-188`), reached because
`lib/tasks/nfl.rake:6` loads that seed unless you pass `SKIP_SCHEDULE=1`:

```ruby
sorted_matchups = slate.slate_matchups.includes(:team, :game).sort_by do |matchup|
  [matchup.game&.kickoff_at || first_game_at, matchup.team.name]   # :182-184
end
sorted_matchups.each_with_index do |matchup, index|
  matchup.update!(rank: index + 1, turf_score: SlateMatchup.turf_score_for(...))
end
```

**This one ranks by KICKOFF TIME, not by expected score.** So it does not produce stale
prices — it produces **wrong** ones: rank 1 (and the 1.0x multiplier) goes to whichever
team kicks off earliest. It runs over weeks 1–17, 256 games, and is the **one site still
unguarded** — a reseed, not a live market rebuild, but it re-ranks picked matchups all the
same.

**And its year is HARDCODED.** `db/seeds/nfl_2026.rb:163` builds
`"NFL 2026 Week #{week}"` regardless of the `YEAR` you passed the rake task. So
`YEAR=2027` makes the pre-flight check below inspect `NFL 2027 %` while the seed rewrites
`NFL 2026 %` — **the check's scope and the command's write set come apart.** Always pass
`SKIP_SCHEDULE=1` unless you specifically intend to reseed the 2026 schedule.

`Nfl::BuildSpanSlate` refuses to rebuild a slate backing live Selections
(`app/services/nfl/build_span_slate.rb:45`). **The ingest service now has an equivalent
guard (site 1, above); the seed path (site 2) does not.** Settlement multiplies by the
stored `turf_score` (`app/models/selection.rb:35`, `:42`), so a reseed via site 2 still
re-prices any picks already locked on the slates it touches — and payouts settle on-chain.

> ⚠️ `slate-build-split` (#263) closed **site 1**. Site 2 lives in the seed and still needs
> its own guard, or the gap survives.

**⚠️ The LIVE command is SEASON-scoped, not week-scoped.** There is no `WEEK` parameter:
`lib/tasks/nfl.rake:4-5` reads only `YEAR` and `CSV_PATH`, and
`app/services/nfl/cache_expected_team_totals.rb:52` iterates **every row of the CSV** — 272
rows spanning weeks 1–18 in the checked-in default. So one run re-ranks **every week the
CSV covers**, and a check that asks about a single week is itself a fail-open.

**Before running step 3, check every slate the run can touch:**

Slate names follow a fixed convention — **`NFL <year> Week <n>`**, written by
`app/services/nfl/cache_expected_team_totals.rb:132` (a span slate is
`NFL <year> Weeks <a>-<b>`, built separately at `app/services/nfl/build_span_slate.rb:57`). That convention is what makes a
season-wide sweep possible:

```bash
bin/rails runner '
  year   = 2026
  slates = Slate.where("name LIKE ?", "NFL #{year} %")
  picked = slates.select { |s| s.slate_matchups.joins(:selections).exists? }
  if slates.empty?
    puts "NO SLATES MATCHING NFL #{year} % — check the year (format: NFL <year> Week <n>)"
  elsif picked.any?
    puts "HAS PICKS — do not re-run. Picked slates (#{picked.size}/#{slates.size}):"
    picked.each { |s| puts "  #{s.name}" }
  else
    puts "safe — #{slates.size} slate(s) for NFL #{year}, none backing picks"
  end'
```

**Three outcomes, deliberately, and season-wide.** THREE fail-open bugs have been found
in this one check across successive reviews, so it is worth stating what each guards
against — the pattern is that the check kept being narrower than the command:

- **Precedence.** An early draft used `slate && … ? "HAS PICKS" : "safe"`. `&&` binds
  tighter than the ternary, so a missing slate was falsy and printed **"safe"**.
- **Scope.** The next draft asked about one week while the command it guards rewrites the
  whole season — checking Week 3 and reading "safe" said nothing about weeks 1, 2, 4–18.
- **Write set.** The check's year is a variable; the seed's is HARDCODED to 2026
  (`db/seeds/nfl_2026.rb:163`). With `YEAR=2027` and no `SKIP_SCHEDULE=1`, the check
  inspects `NFL 2027 %` while the seed rewrites `NFL 2026 %`. The `year` below must match
  the year the command will actually write, which for the seed path is always 2026.

**The check's scope must equal the command's WRITE SET, not its arguments.** That is the
invariant all three bugs violated in different ways.

A settlement-affecting check must never fail open, and it must cover everything the
command it guards can reach. It prints the picked slate **names** so you can see exactly
what would be re-priced.

Full rule and rationale: [[slate-build]], "⛔ The freeze rule — read before running this
on anything live".

---

## Sequence

### 1. Fetch — 🔨 PLANNED (`market-snapshot-impl`)

```bash
# 🔨 PLANNED — package.json defines no `market-snapshot` script (its scrapers are
# `scrape` and `scrape:headed`), so pasting this yields "Missing script".
npm run market-snapshot -- --sport nfl --week 3
```

Drives a headless browser against the DK sportsbook and writes the dataset. Network
lives here and nowhere else.

**Today:** `scripts/scrape_draftkings.js` does this shape for soccer only. It is
hard-wired to a World Cup URL (`scripts/scrape_draftkings.js:22`), carries a country name
map of 48 codes across 59 alias keys (`scripts/scrape_draftkings.js:25`), and picks the
O/U line whose over-odds sit closest to even money
(`scripts/scrape_draftkings.js:146`). Sport, league, and week must become parameters.

**✅ LIVE — the soccer scraper, and its setup.** These prerequisites are live today and
apply to the command below; do not skip them because the heading above is PLANNED:

```bash
# ✅ LIVE — one-time setup
npm install                        # installs playwright transitively via @playwright/test
npx playwright install chromium    # downloads the browser binary

# ✅ LIVE — the soccer scraper as it exists now
npm run scrape                     # or: npm run scrape:headed
```

`scripts/scrape_draftkings.js:14` requires the `playwright` package, which `package.json`
does not declare directly — it resolves transitively through `@playwright/test`, so
`npm install` is enough. Run it from the **primary checkout**
(`/Users/alex/projects/turf-monster`): a fresh worktree has no `node_modules`.

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

🔨 **PLANNED** (`market-snapshot-impl`) — per-week, and does not exist yet:

```bash
bin/rails market:snapshot SPORT=nfl WEEK=3
```

✅ **LIVE** — season-scoped. Run the ⛔ pre-flight check above first:

```bash
bin/rails nfl:expected_team_totals_cache YEAR=2026 SKIP_SCHEDULE=1
bin/rails nfl:expected_team_totals_cache YEAR=2026 SKIP_SCHEDULE=1 CSV_PATH=/path/to/refreshed.csv
```

**`SKIP_SCHEDULE=1` on BOTH lines is not optional.** Without it `lib/tasks/nfl.rake:6`
loads `db/seeds/nfl_2026.rb`, which is unguarded write site 2 above — it re-ranks weeks
1-17 by KICKOFF TIME and its year is hardcoded to 2026 whatever `YEAR` you passed.

Reads the dataset, derives where needed, and upserts one row per team per game.

**`SKIP_SCHEDULE=1` is the lever that makes today's command behave like the pure ingest
this SOP describes.** Without it, `lib/tasks/nfl.rake:6` also loads
`db/seeds/nfl_2026.rb` — the whole season schedule — before ingesting. `CSV_PATH`
(`lib/tasks/nfl.rake:5`) points it at a refreshed line sheet instead of the checked-in default.

**Even with `SKIP_SCHEDULE=1`, this task does far more than ingest.**
`Nfl::CacheExpectedTeamTotals#call` (`app/services/nfl/cache_expected_team_totals.rb:47`)
creates Games (`:117`), creates Slates (`:131`), and creates SlateMatchups (`:143`) and
ranks them (`:180`). Those four belong to [[slate-build]] and move there under
`slate-build-split`.

**Idempotency — correct today, but its grain changes under the split.**
`upsert_projection!` (`app/services/nfl/cache_expected_team_totals.rb:198`) keys on
`(year, week, game_slug, team_slug)`, which is already per-week and needs no change.
`delete_stale_rows` (`:232`) is the problem: it
scopes to `where(year: @year)` and deletes every row the current run did not touch. That
is right today, when one run ingests the **whole season** from one CSV.

⚠️ **It is destructive TODAY, not only after the split.** The refresh procedure this
SOP prescribes at step 2 is to hand-edit or narrow the CSV. Feed it a CSV covering only
week 3 and the year-scoped sweep deletes every *other* week's projections in the same run
— the rows are simply "untouched". So the hazard is not deferred: **any run whose CSV is
narrower than the season deletes the weeks the CSV omits.**

`slate-build-split` must re-scope the sweep to `(year, week)` — do not carry
`delete_stale_rows` across unchanged. Until then, only ever pass a CSV that covers every
week you intend to keep.

### 4. Record the artifact — 🔨 PLANNED (`market-snapshot-impl`)

One `MarketSnapshot` row per run — the historical record of the process having been run:

| Column | Purpose |
|---|---|
| `sport`, `year`, `week` | what was captured |
| `source`, `source_url`, `captured_at` | where it came from, when |
| `dataset_path`, `checksum` | which seed file it wrote |
| `row_count`, `posted_count`, `derived_count` | how much, and by which basis |

Every projection `belongs_to :market_snapshot`. This replaces the debug PNGs in
`scripts/data/` (3.6 MB of committed screenshots) as the record of what ran.

---

## Data touched

**Target state**, once `slate-build-split` lands:

- `team_total_projections` (upsert, delete stale) — today `nfl_team_total_projections`
- `market_snapshots` (insert) — 🔨 planned
- `db/seeds/data/<sport>/*.csv` (write)
- external: DraftKings sportsbook over HTTPS, browser-driven

**Today the ✅ LIVE command in step 3 writes far more than that.**
`nfl:expected_team_totals_cache` also writes:

- `games` (insert, update) — `app/services/nfl/cache_expected_team_totals.rb:117`
- `slates` (insert, update) — `app/services/nfl/cache_expected_team_totals.rb:131`
- `slate_matchups` (insert, update — including **`rank` and `turf_score`**) —
  `app/services/nfl/cache_expected_team_totals.rb:143` and `:194`

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
- **A CSV narrower than the season silently deletes the omitted weeks** —
  `delete_stale_rows` (`app/services/nfl/cache_expected_team_totals.rb:232`) removes every
  untouched row for the whole **year**, so a week-3-only CSV drops weeks 1-2 and 4-18 today.
  See the grain warning in step 3.
- **Re-running against an already-picked week** — see the ⛔ warning above. The ingest
  service now freezes picked matchups (`slate-build-split`,
  `app/services/nfl/cache_expected_team_totals.rb:192`), but a reseed without
  `SKIP_SCHEDULE=1` still re-ranks via the unguarded seed (`db/seeds/nfl_2026.rb:188`).

---

## Related workflows

- [[slate-build]] — the successor. Reads what this SOP writes, and owns everything
  from Slate creation through the frozen multiplier.
