# Centralized Formulas & Slate System

## Formula Source of Truth (SlateMatchup Model)

All scoring/ranking formulas live as class methods on `SlateMatchup` — single source of truth. JS mirrors in `slates/show.html.erb` and `slates/formula_report.html.erb` with comments noting the model as authoritative.

- **Turf Score**: `SlateMatchup.turf_score_for(rank, n, sport:)` — base PINNED to 1.0 (rank 1 always prices x1.0; `Slate#resolved_formula` forces `formula_mult_base` to 1.0 and the Base slider is gone). Sport-keyed curve: fifa `1.0 + 2.0 * ln(rank)/ln(n)` (log decay, x3 top), nfl `1.0 + 1.0 * (rank-1)/(n-1)` (linear, x2 top — NFL scoring runs near-linear by rank per the points-distribution fit, and the flatter cap keeps the Turf and DK chart lines mirrored). Per-slate `formula_mult_scale` overrides either default. On NFL slates the chart's Turf axis renders REVERSED (x1.0 at top) so both lines fall with rank. Repricing pass after formula changes: `bin/rails slates:recompute_turf_scores` (preserves stored ranks).
- **Goals Distribution**: `SlateMatchup.goals_distribution_for(rank, n)` — `0.2 + 4.3 * Math.log(n / rank) / Math.log(n)`. Soccer slates only — the chart series and slider card are hidden on NFL slates. NOTE: the *distribution* is soccer-only, but the `goals` COLUMN is not. Live NFL scoring writes `Goal` rows carrying `points` (a touchdown is 6) and `SlateMatchup#goals` holds a team's POINTS on an NFL slate — see [`workflows/live-scoring.md`](workflows/live-scoring.md). `Game#update_scores_from_goals!` sums `points` rather than counting rows, which leaves every World Cup goal scoring exactly one.

## NFL Points Distribution (historical model)

The NFL analog of the goals distribution, learned from real scores instead of hand-fitted: `Nfl::PointsDistribution` reads the checked-in ESPN dataset (`db/seeds/data/nfl/historical_scores_2023_2025.json`), keeps only full weeks (all 32 teams playing — no byes), ranks each week's 32 team scores, averages actual points by rank, and least-squares fits two curve families:

- **log** (the World Cup family): `base + scale * ln(n/rank)/ln(n)` — 2023-2025 snapshot: `12.52 + 37.84 * ln(32/rank)/ln(32)`, r² 0.9184
- **linear** (best fit for NFL): `base + scale * (n-rank)/(n-1)` — 2023-2025 snapshot: `6.76 + 31.54 * (32-rank)/31`, r² 0.9583

In both, `base` is the rank-32 expectation and `base + scale` the rank-1 expectation. NFL weekly scoring by rank is nearly linear (~1 point per rank, ~46 down to ~4), unlike World Cup goals which decay logarithmically. Refresh the dataset with `bin/rails nfl:fetch_historical_scores`; print the rank table and current fits with `bin/rails nfl:points_distribution`. Bye-week handling (partial weeks) is deliberately out of scope for now.

## Formula Color System

Chart/formula visualization colors are defined once at the top of `slates/show.html.erb`:
- **CSS custom properties** (`--fc-mult`, `--fc-goals`, `--fc-dk-total`) for inline styles
- **JS `FC` object** (`FC.mult`, `FC.goals`, `FC.dkTotal`) for Chart.js datasets
- Colors: Turf Score = violet `#8E82FE`, Goals Distribution = light violet `#B8B0FF`, DK Expectation = green `#4BAF50`

## Slate Show Page (`/slates/:id`)

Admin-only interactive page for tuning multiplier formulas. Key sections:

1. **Slate tabs** — navigate between slates (shown when multiple exist)
2. **Turf Score Formula chart** — Chart.js line chart with 5 datasets (Turf Score, Goals Distribution, DK Total Score, DK Total, DK Total Odds). Updates live as sliders change.
3. **Formula variable sliders** — 6 interactive Alpine.js sliders (A, lineExp, probExp, multScale, goalBase, goalScale) grouped into formula variable cards with colored left accent bars and math notation. multBase is pinned at 1.0 (displayed, not slidable).
4. **Ranking list** — sortable table of all slate matchups. Score/Turf Score columns update dynamically when sliders change. Drag-to-reorder via SortableJS library.
5. **Save buttons** — "Save Rankings" (persists rank order + computed turf scores), "Save Turf Scores" (persists arbitrary slider-computed values), and "Save Formula" (persists current slider values to this slate's DB columns). All appear at top and bottom of the rank list.

### Chart.js + Alpine.js Proxy Avoidance Pattern (Critical)

Chart.js instances **must not** be stored as Alpine reactive properties. Alpine wraps objects in ES6 Proxies, which triggers infinite re-render loops when Chart.js reads/writes its internal state. Solution: store Chart.js instances and shared state as plain globals outside Alpine:

```javascript
var _fcChart = null;       // Chart.js instance
var _fcLastData = null;    // last dataset snapshot
var _fcSliders = {};       // current slider values
```

Alpine components read/write these globals directly. Never use `this.chart` or `$data.chart` for Chart.js objects.

> **Same gotcha applies to DOM refs used with `scrollIntoView`.** Alpine wraps the element in a Proxy, which silently breaks the scroll API. Keep `scrollIntoView` element refs in plain `var`s outside Alpine and call the method from a plain function (see the Slate Manager simulate-all flow below for a working example).

### Theme-Observer Teardown Pattern

The report pages rebuild their charts when the theme toggles by watching `document.documentElement` class changes with a `MutationObserver`. Inline page scripts re-execute on every Turbo visit, so a bare `new MutationObserver(...).observe(...)` leaks one live observer per visit. Convention (see `slates/formula_report.html.erb` and `slates/nfl_report.html.erb`):

- Hold the observer in a plain top-level `var` (outside Alpine, per the proxy rule) declared **without an initializer** — `var _themeObserver;` — so a re-run of the same script (e.g. Turbo preview + fresh render) sees the existing value instead of resetting it.
- Guard creation with `if (!_themeObserver)` so re-runs never stack a second observer.
- Disconnect and null it in a `turbo:before-cache` listener registered with `{ once: true }` inside the same guard, so each visit leaves exactly one teardown listener and departs with zero live observers.

### Cross-Component Communication Pattern

Two Alpine components on the slate show page (`formulaCurves` for the chart/sliders, `rankManager` for the ranking list) communicate via global functions:

- `_fcUpdateRankList(sliders)` — called by `formulaCurves` when sliders change, updates rank list scores
- `_fcSliders` — global object holding current slider values, readable by `rankManager` for save

This avoids Alpine `$dispatch`/`$store` complexity for components that need to share computed state.

### Persisted Formula Variables

7 nullable float columns on `slates`: `formula_a`, `formula_line_exp`, `formula_prob_exp`, `formula_mult_base`, `formula_mult_scale`, `formula_goal_base`, `formula_goal_scale`. Resolution chain (3-tier, like ThemeSetting):

1. **Slate column** — per-slate override (nullable)
2. **Default slate record** — `Slate.find_by(name: "Default")` — global defaults
3. **Hardcoded constant** — `Slate::FORMULA_DEFAULTS`

`Slate#resolved_formula` returns a hash with resolved values. Sliders on the show page initialize from this. "Save Formula" button persists current slider values to the slate. "Default" slate is a config record (filtered out of index/tabs via `where.not(name: "Default")`).

**Admin Formula Defaults page** (`/slates/admin_formula`) — number inputs for editing the Default slate's formula variables. Linked from the admin Link Hub.

## Slate Manager (`/admin/slates/:id/manage`)

Admin page for managing game results within a slate. Each game renders as a card with score table, goal timeline, add goal form, and simulation controls.

### Game Simulation
- **10 ticks** per game, each tick gives both teams a goal chance: `P(goal) = expectedScore / 10`
- Goals POST to the server as real Goal records, assigned to a random player with a random minute (90 min / 10 ticks = 9-minute windows)
- Progress bar animates smoothly via `requestAnimationFrame`
- Toast notifications fire for each goal and at full time
- Two speed options per game card: **Sim 10s** (1s ticks) and **30s** (3s ticks)
- **Simulate All** button at the top: runs all unplayed games sequentially using 10s mode, auto-scrolls to each game card with a 500ms pause before starting
- `simulateGame()` returns a Promise for sequential chaining
- DOM element references kept outside Alpine's Proxy to ensure `scrollIntoView` works correctly

## Slate Routes

- `/slates` — redirects to next upcoming slate (or most recent)
- `/slates/:id` — show (chart + sliders + rank list)
- `/slates/:id/update_rankings` — PATCH, save drag-reordered ranks + recalculated multipliers
- `/slates/:id/update_turf_scores` — PATCH, save slider-computed turf score values
- `/slates/:id/update_formula` — PATCH, save formula slider values to this slate
- `/slates/formula_report` — DK Score formula iterations page (soccer) with comparison charts + playground; link-tabs to the NFL report
- `/slates/nfl_report` — NFL points-distribution report (rank chart, linear + log fits, rank table) on its own tab; linked from the admin dashboard and the admin Link Hub
- `/slates/admin_formula` — GET, admin page for editing Default slate formula variables
- `/slates/update_admin_formula` — PATCH, save Default slate formula variables
