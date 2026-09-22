# Centralized Formulas & Slate System

> **Code is law, for the citations here.** A `path/to/file.rb:NN` names this
> repo's code, and a bare `:NN` inherits the file of the nearest preceding
> path-qualified citation — file context resets at each `##` heading.
> `test/docs/workflow_citation_docs_test.rb` checks every number against the
> symbol its prose names and reddens when one stops landing on it. This document
> carries one such number, and it gets the STRONG form of that check:
> **1 of the 1 citations** here sits inside the definition its prose names, and
> the other **0** ride the weaker literal fallback.
> **A formula is not a coordinate.** This guard checks the one number, not the
> curves quoted beside it. This document is also cited BY LINE from
> `docs/workflows/slate-build.md`, so a line inserted above the fits moves them —
> repoint that document in the same commit.

## Formula Source of Truth (SlateMatchup Model)

All scoring/ranking formulas live as class methods on `SlateMatchup` — single source of truth. The admin board (`slates/show.html.erb`) holds **no mirror**: it looks up a price table Ruby renders (`SlatesHelper#turf_score_scale_table`). A JS copy of the curve rounded a tie differently, and "Save Multipliers" persists the number on screen, so the copy could write a price the curve never produced. `slates/formula_report.html.erb` still mirrors the soccer curve, and may, because that page only reports — it saves nothing. The server now also BOUNDS what that page may post back (`SlateMatchup.price_band`), derived from the same curve and the same `SlateMatchup::SLIDER_SCALES` the table is built from — see **Bounding a hand-entered multiplier** under Slate Routes.

- **Turf Score**: `SlateMatchup.turf_score_for(rank, n, sport:)` — base PINNED to 1.0 (rank 1 always prices x1.0; `Slate#resolved_formula` forces `formula_mult_base` to 1.0 and the Base slider is gone). Sport-keyed curve: fifa `1.0 + 2.0 * ln(rank)/ln(n)` (log decay, x3 top), nfl `1.0 + 1.0 * (rank-1)/(n-1)` (linear, x2 top — NFL scoring runs near-linear by rank per the points-distribution fit, and the flatter cap keeps the Turf and DK chart lines mirrored). **Both curves are rounded to ONE DECIMAL** (`app/models/slate_matchup.rb:74`), and that rounded value is what freezes onto the matchup row and what `Selection#compute_points!` settles from — so the curve alone does not reproduce the multiplier a player is PAID. On the 32-team NFL curve that collapses ranks 1-2 to x1.0 and ranks 3, 4 and 5 all to x1.1; computing rank 5 as 1.129 and expecting to be paid it is wrong. The public rules page at `/turf-monster-v1` carries this caveat and this doc must not contradict it. Per-slate `formula_mult_scale` overrides either default. On NFL slates the chart's Turf axis renders REVERSED (x1.0 at top) so both lines fall with rank. Repricing pass after formula changes: `bin/rails slates:recompute_turf_scores` (preserves stored ranks; skips a two-line span — see **Two lines** below).
- **Goals Distribution**: `SlateMatchup.goals_distribution_for(rank, n)` — `0.2 + 4.3 * Math.log(n / rank) / Math.log(n)`, rounded to two decimals. Soccer slates only — the chart series and slider card are hidden on NFL slates. NOTE: the *distribution* is soccer-only, but the `goals` COLUMN is not. Live NFL scoring writes `Goal` rows carrying `points` (a touchdown is 6) and `SlateMatchup#goals` holds a team's POINTS on an NFL slate — see [`workflows/live-scoring.md`](workflows/live-scoring.md). `Game#update_scores_from_goals!` sums `points` rather than counting rows, which leaves every World Cup goal scoring exactly one.

## NFL Points Distribution (historical model)

The NFL analog of the goals distribution, learned from real scores instead of hand-fitted: `Nfl::PointsDistribution` reads the checked-in ESPN dataset (`db/seeds/data/nfl/historical_scores_2023_2025.json`), keeps only full weeks (all 32 teams playing — no byes), ranks each week's 32 team scores, averages actual points by rank, and least-squares fits two curve families:

- **log** (the World Cup family): `base + scale * ln(n/rank)/ln(n)` — 2023-2025 snapshot: `12.52 + 37.84 * ln(32/rank)/ln(32)`, r² 0.9184
- **linear** (best fit for NFL): `base + scale * (n-rank)/(n-1)` — 2023-2025 snapshot: `6.76 + 31.54 * (32-rank)/31`, r² 0.9583

In both, `base` is the rank-32 expectation and `base + scale` the rank-1 expectation. NFL weekly scoring by rank is nearly linear (~1 point per rank, ~46 down to ~4), unlike World Cup goals which decay logarithmically. Refresh the dataset with `bin/rails nfl:fetch_historical_scores`; print the rank table and current fits with `bin/rails nfl:points_distribution`. Bye-week handling (partial weeks) is deliberately out of scope for now.

## Two lines: a bye inside a span

A three-week NFL span holds two games, not three, for a team whose bye falls inside it. Two rules keep that team fairly priced (the full rationale sits above `Slate.game_factor` in `app/models/slate.rb`):

- **Rank on points per game.** `Slate#team_rankings` sorts on `Slate.expected_points_per_game`, not the summed total, so a strong bye team ranks on its strength. With every team on the same game count (any one-week slate; weeks 1-3 and 16-18 of 2026) per-game order is summed order, and nothing re-prices.
- **Price on the team's line.** `SlateMatchup.turf_score_for(..., game_factor:)` scales the curve by `span_games / games` before rounding: full-span teams stay on x1.0-x2.0, and a two-of-three team rides the **bye line**, x1.5-x3.0. Two games at 1.5m score what three games at m do.

The admin slate page states the rule, badges each bye team, and its JS mirror applies the same factor, so a drag or "Save Multipliers" keeps a bye team on its line. To move an already-built span onto the rule: `bin/rails "slates:reprice_span[<slug>]"` (dry run), then `APPLY=1`; a slate with paid picks also needs `REPRICE_PAID_PICKS=<slug>`, and a slate that has kicked off is refused outright.

## Formula Color System

Chart/formula visualization colors are defined once at the top of `slates/show.html.erb`.
**Each series has TWO tokens, and picking the wrong one is an accessibility bug**:

| Series | Fill (graphics) | Ink (small text) |
|---|---|---|
| Turf Score | `--fc-mult` `#8E82FE` | `--fc-mult-ink` |
| Goals Distribution | `--fc-goals` `#B8B0FF` | `--fc-goals-ink` |
| DK Score | `--fc-dk-score` `#15803D` | `--fc-dk-score-ink` |
| DK Expectation | `--fc-dk-total` `#4BAF50` | none — graphics only |

- **Fill** paints graphical objects only: the chart stroke, the panel's
  `border-left`, the sliders' `accent-color`. Those are graphical objects, so
  the bar they owe is WCAG 1.4.11's 3:1 rather than 4.5:1 — but **three of the
  four fills are UNDER that bar in one theme**, so "the brand colours are
  correct there" (what this said until 2026-09-22) was not true. Measured on
  the card the graphics sit on, by `test/views/violet_text_contrast_test.rb`'s
  own helpers: `--fc-goals` **1.96:1** light, `--fc-dk-score` **2.22:1** dark,
  `--fc-dk-total` **2.78:1** light; only `--fc-mult` clears both (3.10 / 3.60).
  The 1.96 and 2.22 quoted below as the *text* failure are also under the
  *graphical* floor. This is pre-existing and was not introduced by the ink
  work — the fills are byte-identical before and after it — and the fix is
  tracked separately as `raise-series-fills-graphical-floor`. Do not read this
  bullet as a clearance.
- **Ink** paints anything read as small TEXT, which owes 4.5:1. Only the theme
  that actually fails moves, so a series keeps its own brand colour wherever it
  already clears: `--fc-goals-ink` is `#B8B0FF` in dark and `--color-violet-ink`
  in light; `--fc-dk-score-ink` is `#15803D` in light and `--color-primary-ink`
  in dark. Both borrowed inks are **this app's own per-theme tokens**, declared
  in `app/assets/tailwind/application.css` — `Studio::ThemeResolver` emits
  neither (it emits `--color-primary` and its scale, plus the danger, warning
  and success inks). Borrowing them still beats pinning a fourth hex pair,
  because they move with the ink tokens the rest of the app already reads; but
  none of the four values here tracks a theme change, and until 2026-09-22 this
  line claimed they did. What the theme DOES move is the **ground**: the four
  surfaces are resolver-derived, so changing the dark base shifts every ratio
  above while the inks stay put. The guard catches that by reddening.
- **JS `FC` object** (`FC.mult`, `FC.goals`, `FC.dkTotal`) for Chart.js
  datasets — strokes, so it reads the fills.
- Guard: `test/views/violet_text_contrast_test.rb` resolves every inline
  `color:` through these tokens and measures it against the surface the element
  actually sits on, in both themes. Reaching for a fill as text fails the suite.

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
- `/slates/:id/update_turf_scores` — PATCH, save slider-computed turf score values. **Bounded and strictly parsed** — see below
- `/slates/:id/update_formula` — PATCH, save formula slider values to this slate
- `/slates/formula_report` — DK Score formula iterations page (soccer) with comparison charts + playground; link-tabs to the NFL report
- `/slates/nfl_report` — NFL points-distribution report (rank chart, linear + log fits, rank table) on its own tab; linked from the admin dashboard and the admin Link Hub
- `/slates/admin_formula` — GET, admin page for editing Default slate formula variables
- `/benchmarks(/:slug)` — PUBLIC, read-only. The pricing board a player can check: per-team points per game, rank, frozen multiplier, the bye line where one applies, and when the lines were pulled. Reads stored values only. Rebuild those values with `bin/rails market:refresh` (see [`workflows/market-snapshot.md`](workflows/market-snapshot.md) step 5)
- `/slates/update_admin_formula` — PATCH, save Default slate formula variables

### Bounding a hand-entered multiplier

`SlatesController#update_turf_scores` is the one endpoint that writes a price
nobody computed, and `turf_score` is the column `Selection#compute_points!`
settles from. It used to write `entry[:turf_score].to_f.round(1)` through
`update_all` — no bound, no validation, and `update_all` skips validations by
construction, so the guard has to sit at the write rather than on the model.

Two rules now run over EVERY posted row before ANY row is written; one bad row
refuses the whole batch, because the board posts all 32 rows in one form and a
half-written board is worse than a refusal.

**The refusal message is CAPPED, and that cap is a correctness rule, not
tidiness.** The flash is serialized into the session cookie, which
ActionDispatch caps at 4096 bytes and raises `CookieOverflow` past — from
middleware, AFTER the action returns, where `update_turf_scores`' own
`rescue StandardError` cannot see it. Measured against the real seeded slates
with every row refused, each under the band its own `admin_price_band` emits:
**World Cup 2026 Group 1** (48 teams, `x1.0-x11.0`) gives **2,559** bytes, and
**NFL 2026 Preseason Week 4** (32 teams, the same band) gives **1,994**. Name
the roster and the band — a figure whose construction is unstated is not
reproducible, and an earlier revision of this line quoted a roster that was not
a slate and then a band label the code cannot emit (`price_band`'s `top` is at
least `SLIDER_SCALES.max`, so the ceiling is at least `x11.0` on any slate with
**n ≥ 2** teams — `turf_score_for` returns early at `n <= 1`, so a zero- or
one-team slate bands at `x1.0-x1.0`). Neither exceeds 4096 alone, which is exactly why it was latent — the
alert is only part of the session, so it 500s for an admin whose session is
already full and not for one who just signed in. The controller now names the
first three teams and appends `and N more.`, bounded by BYTES as well as by
count (`SlatesController::REFUSAL_MAX_BYTES`) so the ceiling does not rest on a
claim about how long a team name is.

- **Readable** — `SlateMatchup.parse_turf_score` uses `Kernel#Float`, which
  raises rather than guessing. `String#to_f` misreads in two ways and announces
  neither: it ZEROES an empty cell, an unpriced row's `—` and a leading-x
  `"x2.5"`, and it TRUNCATES a trailing-x `"2.5x"` to 2.5. The em dash is
  reachable from the page itself — an unranked row renders `—x`, and
  `saveMultipliers` posts the display text.
- **In band** — `Slate#admin_price_band`, built by `SlateMatchup.price_band`
  from this curve and `SlateMatchup::SLIDER_SCALES`.

**The band is a deliberate OVERRIDE band, wider than the slate's resolved
curve** — the widest price this slate's own board can display: `x1.0` up to
`(1.0 + TOP) * the widest game_factor here` (x11.0 on a one-week slate, x16.5
on a span with a two-of-three bye team). It is NOT the curve's own range,
because the scale slider runs 0-10, repaints every row live, and "Save
Multipliers" is a separate button from "Save Formula" — a bound at the resolved
curve's top would refuse the operator's own screen, and a guard that fires on
correct work gets deleted.

**`TOP` is `max(10, the slate's resolved scale)`, not a flat 10**, because the
board is not only the 21 slider positions: `turf_score_scale_table` builds its
rows from `SLIDER_SCALES + [resolved_scale]`, so a slate whose
`formula_mult_scale` sits off the grid gets an extra row the slider cannot
reach. The band reads the same expression the view feeds that helper, so the
sentence above is true by construction rather than by coincidence. It did not
used to be: measured on a 32-team NFL slate against the flat-10 band, a resolved
scale of 20 put 16 of 32 board rows outside the band and a scale of 100 put 28
of 32 outside — every one of them a price the operator's own screen had just
drawn. Nothing in production reaches it (`formula_mult_scale` is NULL on every
slate today), so it was a latent contradiction rather than an outage. A resolved
scale BELOW the grid cannot narrow the band; the slider is still on the page.

**A row that already holds an out-of-range scale becomes unsaveable by any
writer** — `save` returns false with an error about a column the writer never
touched. No validated path can create one; only `update_column`, raw SQL or a
restored backup can. Clear **only the out-of-range rows** rather than loosening
the rule — an unscoped `update_all` takes every legitimately configured scale
with it:

```ruby
Slate.where("formula_mult_scale < 0 OR formula_mult_scale > ?", SlateMatchup::SLIDER_SCALES.max)
     .update_all(formula_mult_scale: nil)
```

The FLOOR is not a judgment call. Every price the curve can emit is
`(1.0 + scale * curve) * game_factor` with `scale >= 0`, `curve >= 0` and
`game_factor >= 1.0`, so `x1.0` is its structural minimum. Below that is a bug,
not a cheap team. What the band deliberately still lets through: on a one-week
slate topping at x2.0, a hand-typed x3.5 is accepted, because the slider can put
x3.5 on that same screen and the server cannot tell the two apart.

<!-- citation-guard: enforced -->
