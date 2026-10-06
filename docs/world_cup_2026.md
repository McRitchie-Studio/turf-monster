# FIFA World Cup 2026

## Overview

- **Hosts**: USA, Canada, Mexico (tri-host)
- **Teams**: 48 (expanded from 32 in 2022)
- **Dates**: June 11 – July 19, 2026
- **Venues**: 16 stadiums across 16 cities (11 US, 3 Mexico, 2 Canada)

## Group Stage Structure

- **12 groups** of 4 teams each (Groups A–L)
- **3 matchdays** per group (each team plays 3 matches)
- **24 matches per matchday** (72 total group stage matches)
- **Advancement**: Top 2 per group (24) + 8 best third-place teams = 32 to knockout round

### Matchday Schedule

| Matchday | Dates | Matches |
|----------|-------|---------|
| 1 | June 11–17 | 24 |
| 2 | June 18–23 | 24 |
| 3 | June 24–27 | 24 |

Each matchday, every team plays exactly once. Each match produces 2 "offensive matchups" (one per team).

### Group Play Round-Robin

Within each group of 4 teams (A, B, C, D):
- Matchday 1: A vs B, C vs D
- Matchday 2: A vs C, B vs D
- Matchday 3: A vs D, B vs C

## 2026 Groups (Confirmed Draw)

| Group | Teams |
|-------|-------|
| A | Qatar, Ecuador, Colombia, UEFA Playoff A |
| B | Canada, Morocco, Australia, UEFA Playoff B |
| C | USA, Serbia, Cameroon, New Zealand |
| D | Brazil, Nigeria, IC Playoff 1, UEFA Playoff C |
| E | Argentina, Peru, Egypt, IC Playoff 2 |
| F | Mexico, Honduras, Senegal, UEFA Playoff D |
| G | France, Colombia (TBC), Panama, Uzbekistan |
| H | Portugal, Iran, South Korea, Northern Ireland |
| I | Spain, Japan, Chile, Bolivia |
| J | England, Denmark, Paraguay, Ivory Coast |
| K | Germany, Uruguay, Costa Rica, Saudi Arabia |
| L | Italy, Belgium, Albania, Dominican Republic |

*UEFA Playoff and IC Playoff slots TBD (decided March 26-31, 2026)*

## Knockout Stage

- **Round of 32**: 32 teams, single elimination
- **Round of 16 → Quarterfinals → Semifinals → Final**
- **Third-place match**: Yes
- **Extra time + penalties**: For drawn knockout matches

## Key Format Change from 2022

2022 had 32 teams in 8 groups of 4. FIFA originally considered 16 groups of 3 for 48 teams but chose 12 groups of 4 to reduce collusion risk and maintain competitive integrity.

## Turf Monster Data

The app's seed data includes:
- **48 teams** with emoji, colors, group assignments
- **31 knockout-slot placeholder teams** for unresolved advancement positions
- **104 tournament games**: 72 group-stage games plus 32 elimination-round fixtures
- **67 notable players** across 21 teams
- **24 Matchday 1 props** with goal lines (1.5–2.5 range)

### Offensive Matchups Per Matchday

Each matchday produces **48 offensive matchups** (one per team). For Turf Totals contests, each matchup represents one team's goal-scoring opportunity in their specific game. Example:

- Game: USA vs Serbia (Matchday 1)
- Offensive matchup 1: USA's offense vs Serbia's defense
- Offensive matchup 2: Serbia's offense vs USA's defense

These are ranked by expected scoring output. Strong offenses against weak defenses rank high (low multiplier). Weak offenses against strong defenses rank low (high multiplier).

### Knockout Slates

`WorldCup2026KnockoutSeed` adds one slate per elimination stage:

- World Cup 2026 Round of 32
- World Cup 2026 Round of 16
- World Cup 2026 Quarter-finals
- World Cup 2026 Semi-finals
- World Cup 2026 Third Place
- World Cup 2026 Final

The fixture list is sourced from FIFA's FDCP season calendar for competition
`17`, season `285023`. Known teams use the existing team records by FIFA
abbreviation; unresolved bracket positions use placeholder teams such as
`W101` or `Runner-up Match 101` so games and slate matchups can be created
before the full bracket is settled.

For deploys that need to apply only this data change, run the narrow idempotent
task `bin/rails wc:seed_knockout`; do not run the full `db:seed` as a
post-deploy hook.

Turf Totals contests normally require 6 picks. Short knockout slates require all
available matchup cards instead, so semi-final contests require 4 picks and the
third-place/final contests require 2 picks.

## World Cup Survivor (retired)

The survivor format is retired. Turf Totals is the one game the app runs, and
nothing creates, enters, picks or grades a survivor contest. A contest row the
format wrote stays a readable closed record: `game_type` reads as `nil`,
`Contest#retired_format?` is true, its page renders final standings from the
entries' stored rank and payout, and every entry and grading action refuses it
(`ContestsController#refuse_retired_format`). The `survivor_rounds` and
`survivor_picks` tables, `games.survivor_round_id` and `entries.eliminated_round`
stay in the schema with no model or writer; mainnet and QA held no survivor rows
when the format was retired.
