# Workflow: market-snapshot

> **Code is law.** Every claim below cites `path/to/file.rb:NN` from the current
> codebase. Re-verify on edit — line numbers drift on refactor.
>
> **Status: MOSTLY LIVE.** The derive math, the per-week ingest, the `MarketSnapshot`
> artifact, and the posted/derived basis all run today. The one remaining 🔨 PLANNED
> piece is the NFL DraftKings *fetch*: the scraper is generalized (sport/league/week
> parameters, `npm run market-snapshot`), but only the soccer parser is wired, so NFL
> numbers are still hand-transcribed. Every step below is marked ✅ LIVE or 🔨 PLANNED
> with its task. Do not read a 🔨 step as something you can run now.

**Trigger:** Operator command, weekly per sport — before [[slate-build]]
**Actors:** Operator · DraftKings sportsbook (public web) · Postgres
**Outcome:** A seed-format dataset on disk, one projection row per team per game, and
one `MarketSnapshot` artifact row recording the run.
(🔨 The projection table is still `nfl_team_total_projections`; its target-state rename
to `team_total_projections` belongs to `slate-build-split`, not this SOP.)
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
(`app/services/nfl/cache_expected_team_totals.rb:25` is the `def`; the arithmetic is at
`:28` and `:30`). Paraphrased below for readability — the real locals are `total` and
`spread`:

```ruby
home_points = ((game_total - home_spread) / 2).round(2)
away_points = (game_total - home_points).round(2)
```

The away side is `total - home`, not `(total + spread) / 2`. Both are algebraically the
same; only the first guarantees the two sides sum to exactly the game total after
rounding.

Sign convention, resolved at `app/services/nfl/cache_expected_team_totals.rb:313`
(`home_spread_for`): **the favorite's spread is negative.** When the home team is the
favorite, `home_spread` is that negative number. When the away team is the favorite,
`home_spread` is its absolute value. A row whose `favorite_team_slug` matches neither
side falls through to `0`.

**Re-running upgrades a week's projections in place.** A Week 3 snapshot taken in July is
`derived`; the same command on the Thursday of Week 3 overwrites it with `posted`. It is a
genuine overwrite, not an accumulation: the upsert key is one row per
`(year, week, game_slug, team_slug)`
(`app/services/nfl/cache_expected_team_totals.rb:266`), so a week holds exactly one
projection per team and the derived value is gone once posted lands.

✅ **LIVE (`market-snapshot-impl`):** the `posted_line` column keeps DK's posted number
alongside the derived one, so the gap between DK's line and ours is a standing accuracy
check on the formula above. When a side is posted, `basis` is `posted` and
`expected_points` uses DK's number as-is; otherwise `basis` is `derived` and the value
falls back to the formula (`market_for`, `:172`). No NFL row is `posted` yet — the
checked-in CSV is Yahoo-derived — so the comparison waits on the NFL fetch (step 1).

---

## ⛔ Today, re-running this SOP can re-price a live contest

**This warning belongs here, not only in [[slate-build]], because the dangerous command is
in THIS file** (step 3).

`slate-build-split` (#263) closed the ingest service's own re-rank, so the ✅ LIVE command
`nfl:expected_team_totals_cache` now rewrites **`rank` and `turf_score`** from **one guarded
site and one still-unguarded one**. The still-open one — the schedule seed — is the nastier
one.

**Site 1 — the ingest's own re-rank — ✅ NOW GUARDED (`slate-build-split`, #263).**
`rank_slate_matchups!` (`app/services/nfl/cache_expected_team_totals.rb:247`) skips any
matchup a player has already picked before it rewrites the row:

```ruby
next if matchup.selections.exists?                                       # :259 — the guard
matchup.update!(rank: ranking[:rank], turf_score: ranking[:turf_score])  # :261
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
`app/services/nfl/cache_expected_team_totals.rb:67` iterates **every row of the CSV** (the
season task passes no `week`, so no row is filtered out) — 272
rows spanning weeks 1–18 in the checked-in default. So one run re-ranks **every week the
CSV covers**, and a check that asks about a single week is itself a fail-open.

**Before running step 3, check every slate the run can touch:**

Slate names follow a fixed convention — **`NFL <year> Week <n>`**, written by
`app/services/nfl/cache_expected_team_totals.rb:199` (a span slate is
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

### 1. Fetch — ✅ LIVE for soccer · 🔨 PLANNED for NFL (`market-snapshot-impl`)

```bash
# ✅ LIVE — the generalized entry point. Sport/league/week are parameters and the
# `market-snapshot` script now exists (npm run scrape stays as a back-compat alias).
npm run market-snapshot                                   # default: soccer/world-cup-2026
npm run market-snapshot -- --sport soccer --league world-cup-2026 --week 3

# 🔨 PLANNED — the NFL slot is registered but has no wired parser, so this aborts
# loudly ("🔨 PLANNED: no DraftKings scraper is wired for nfl/regular-season yet").
npm run market-snapshot -- --sport nfl --week 3
```

Drives a headless browser against the DK sportsbook and writes the dataset. Network
lives here and nowhere else.

**Today:** `scripts/scrape_draftkings.js` is now generalized around a `LEAGUES` registry
keyed by `<sport>/<league>` (`scripts/scrape_draftkings.js:54`), each entry holding a
URL, team-name map, market label, and parser. The World Cup soccer entry is the one
**wired** parser — the pure `parseTeamTotals` seam
(`scripts/scrape_draftkings.js:100`) turns page text into rows and is total over garbled
input (a layout change yields `[]`, so a caller can assert a minimum row count).
Debug screenshots + raw page dumps are now opt-in (`--debug`/`--headed`) and git-ignored
— they are no longer committed. The `nfl/regular-season` entry is registered but its
parser is `null`: the NFL market posts team totals as **points** (plus game total +
spread) on a differently shaped page whose markup is not yet mapped, so it fails loudly
rather than guess. Wiring that parser is the remaining 🔨 PLANNED step; until then NFL
numbers are hand-transcribed (step 2). This is verified by a dep-free unit suite
(`npm run test:scrape`, `scripts/scrape_draftkings.test.js`).

**✅ LIVE — the soccer scraper, and its setup.** These prerequisites are live today and
apply to the command below; do not skip them because the heading above is PLANNED:

```bash
# ✅ LIVE — one-time setup
npm install                        # installs playwright transitively via @playwright/test
npx playwright install chromium    # downloads the browser binary

# ✅ LIVE — the soccer scraper as it exists now
npm run scrape                     # or: npm run scrape:headed
```

`scripts/scrape_draftkings.js:221` requires the `playwright` package (lazily, inside the
browser run, so the pure parser can be unit-tested without it), which `package.json`
does not declare directly — it resolves transitively through `@playwright/test`, so
`npm install` is enough. Run it from the **primary checkout**
(`/Users/alex/projects/turf-monster`): a fresh worktree has no `node_modules`.

**Pattern to copy:** `Nfl::FetchHistoricalScores` (`app/services/nfl/fetch_historical_scores.rb:9`)
already models fetch-to-checked-in-dataset correctly — network only on the rake task, a
pure parse seam at `:26` that turns a payload into rows and is total over empty input.

### 2. Write the dataset — 🔨 PLANNED for the NFL scraper · ✅ LIVE columns (`market-snapshot-impl`)

Output path: `db/seeds/data/<sport>/<year>-w<NN>-team-totals.csv`

Seed format is deliberate: a plain checked-in file is what carries this data into QA and
production without a database dump.

Columns — extending the live header at `db/seeds/data/nfl/2026_expected_team_totals.csv`:

| Column | Notes |
|---|---|
| `week`, `away_team_slug`, `home_team_slug` | ✅ live today |
| `favorite_team_slug`, `favorite_spread`, `game_total` | ✅ live today — the primitives |
| `source`, `source_published_on`, `source_url`, `source_text` | ✅ live today — provenance |
| `home_posted_line`, `home_over_odds`, `home_under_odds` | ✅ ingested — DK's home number, blank when unposted |
| `away_posted_line`, `away_over_odds`, `away_under_odds` | ✅ ingested — DK's away number, blank when unposted |

Posted lines are **per side** (`home_`/`away_`, mirroring the existing
`home_team_slug`/`away_team_slug`) because DK posts a separate team total for each side.
The ingest reads these optional columns and **stamps `basis` itself** on each projection:
`posted` when that side carries a `*_posted_line` (used as-is), else `derived`. `basis`
is therefore a projection column, not a CSV column. Every column above is blank in the
checked-in Yahoo-derived CSV; they light up once the NFL fetch (step 1) lands.

**⚠️ Today's NFL numbers did not come from DraftKings.** The checked-in
`db/seeds/data/nfl/2026_expected_team_totals.csv` was **hand-transcribed from a Yahoo
article** — its `source` column reads `yahoo_sports_2026_lookahead`, with the article URL
in `source_url` and the quoted line in `source_text`. Every row is `derived`; none is
`posted`.

So until step 1 ships, **today's actual refresh procedure is manual**: edit or replace the
CSV by hand, keep the `source*` columns honest, then run step 3 with
`CSV_PATH=/path/to/your.csv`. There is no NFL scraper to run.

### 3. Ingest — ✅ LIVE (per-week `market:snapshot`, or season-scoped `nfl:expected_team_totals_cache`)

✅ **LIVE** (`market-snapshot-impl`) — the pure per-week ingest, and the preferred one.
Unlike the season task it **never loads the schedule seed** (`lib/tasks/market.rake`),
so it cannot trip the unguarded site-2 re-rank; it narrows to `WEEK` and records one
`MarketSnapshot` artifact per run:

```bash
bin/rails market:snapshot SPORT=nfl WEEK=3
bin/rails market:snapshot SPORT=nfl WEEK=3 CSV_PATH=/path/to/refreshed.csv
```

✅ **LIVE** — season-scoped (whole CSV in one run). Run the ⛔ pre-flight check above first:

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

**Idempotency — per-week at both grains.**
`upsert_projection!` (`app/services/nfl/cache_expected_team_totals.rb:266`) keys on
`(year, week, game_slug, team_slug)`, which is per-week and needs no change.
`delete_stale_rows` (`:305`) is **now scoped to the weeks the run actually built**
(`where(year: @year, week: @touched_weeks)`), not to the whole year — so a CSV narrower
than the season only sweeps the weeks it covered, and the per-week `market:snapshot`
(step 3) is safe by construction.

✅ **The old cross-week hazard is closed.** Feeding a week-3-only CSV once deleted every
*other* week's projections in the same run (they were simply "untouched" under the
year-wide sweep). The sweep is now week-scoped, and that guard is mutation-verified by
`test/services/nfl/cache_expected_team_totals_safety_test.rb` ("stale sweep removes ONLY
the rebuilt week, leaving other weeks intact").

### 4. Record the artifact — ✅ LIVE (`market-snapshot-impl`)

One `MarketSnapshot` row per run (`app/models/market_snapshot.rb`,
`market_snapshots` table) — the historical record of the process having been run.
`Nfl::CacheExpectedTeamTotals` writes it inside the ingest transaction
(`build_snapshot!`, `:88`) and stamps every projection with it:

| Column | Purpose |
|---|---|
| `sport`, `year`, `week` | what was captured (`week` is null for a season-wide run) |
| `source`, `source_url`, `captured_at` | where it came from, when |
| `dataset_path`, `checksum` | which seed file it read, SHA-256 pinned |
| `row_count`, `posted_count`, `derived_count` | how much, and by which basis (`row_count == posted + derived`) |

Every projection `belongs_to :market_snapshot` (optional, so pre-existing rows survive;
the ingest stamps it on every upsert going forward). This **replaces the committed debug
PNGs** — the ~3.5 MB of screenshots in `scripts/data/` are now removed and git-ignored,
and the artifact row is the record of what ran.

---

## Data touched

**Target state**, once `slate-build-split` lands:

- `team_total_projections` (upsert, delete stale) — today `nfl_team_total_projections`
- `market_snapshots` (insert) — ✅ live
- `db/seeds/data/<sport>/*.csv` (write)
- external: DraftKings sportsbook over HTTPS, browser-driven

**Today the ✅ LIVE command in step 3 writes far more than that.**
`nfl:expected_team_totals_cache` also writes:

- `games` (insert, update) — `app/services/nfl/cache_expected_team_totals.rb:184`
- `slates` (insert, update) — `app/services/nfl/cache_expected_team_totals.rb:198`
- `slate_matchups` (insert, update — including **`rank` and `turf_score`**) —
  `app/services/nfl/cache_expected_team_totals.rb:210` and `:261`

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
  `? Unknown team` and skips the row (`scripts/scrape_draftkings.js:126`). A skipped row
  silently shortens the slate. Count skips, print them, and fail the run when any team in
  the week is unresolved.
- **DK markup changes** — the scraper parses `document.body.innerText`
  (`scripts/scrape_draftkings.js:246`), so a layout change yields zero rows rather than an
  exception. Assert a minimum row count for the week before writing the dataset.
- **A CSV narrower than the season** — no longer a data-loss hazard:
  `delete_stale_rows` (`app/services/nfl/cache_expected_team_totals.rb:305`) is scoped to
  the weeks the run built (`@touched_weeks`), so a week-3-only CSV sweeps only week 3.
  See the idempotency note in step 3.
- **Re-running against an already-picked week** — see the ⛔ warning above. The ingest
  service now freezes picked matchups (`slate-build-split`,
  `app/services/nfl/cache_expected_team_totals.rb:259`), but a reseed without
  `SKIP_SCHEDULE=1` still re-ranks via the unguarded seed (`db/seeds/nfl_2026.rb:188`).

---

## Related workflows

- [[slate-build]] — the successor. Reads what this SOP writes, and owns everything
  from Slate creation through the frozen multiplier.
