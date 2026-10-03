# Agent API

A JSON API that lets an AI agent act for one Turf Monster player without a
browser. This page is the contract for what is shipped. It supersedes the
authentication design in [`BOT_API.md`](BOT_API.md).

**Shipped so far:** API keys, bearer authentication, `GET /api/v1/me`, the
rate-limit tier, the read endpoints for contests, leaderboards and the player's
entries, and the two writes: [create an entry](#post-apiv1contestsslugentries)
and [replace its picks](#patch-apiv1entriesslug), and [the agent
pages](#the-agent-pages) (`/agents`, `/agents/guide`, its Markdown twin and
`/llms.txt`), and [an MCP endpoint](#mcp) (`POST /mcp`) that serves the same
operations as tools.

## The key

A player creates a key on their account page (`/account`, the **Agent API keys**
card), gives it a name, and hands it to their agent.

| Property | Value |
|----------|-------|
| Format | `tmk_` followed by 40 letters and digits |
| Shown | Once, in the card, in the response to the create request. It cannot be recovered. |
| Stored | A SHA-256 digest and the first 10 characters (the display prefix). Never the key. |
| Lifetime | 90 days from creation |
| Name | Required, up to 40 characters. It is how the player tells their keys apart. |
| Limit | 5 active keys per player |
| Revoke | Any time, from the same card. Takes effect on the next request. |

The new key is on screen only until the player dismisses it or leaves the page.
The block that shows it is marked `data-turbo-temporary`, so the browser's Back
button does not bring it back from Turbo's page snapshot. The card restored that
way lists the key and offers **Add another API key**.

Creating keys is throttled to 10 an hour per IP address. Past that, the card
says so and creates nothing. A revoke the server refuses (the key is no longer
on the account, or the write failed) is also answered inside the card.

### Eligibility is checked when the key is created

An API request comes from the agent's servers, so its IP address says nothing
about where the player is. Eligibility is therefore decided once, in the
player's own browser, when they create the key, and the verdict is recorded on
the key:

- **Location.** The same gate a contest entry runs. A player in a restricted
  state, or one whose location cannot be resolved, cannot create a key.
- **Age.** When the entry age gate is on (`ENABLE_AGE_GATE`), the player must
  already have verified their date of birth.
- A frozen account cannot create a key, and an admin acting as another user
  cannot create one for them.

API requests do not repeat the location check. The 90-day lifetime is what
bounds how old that verdict can get.

Two things are asked again at request time, because the key's stamp cannot
answer for them:

- **The account hold.** A frozen account is refused on every request that is
  not a `GET` or a `HEAD`. Reads keep working.
- **Age, on endpoints that enter a contest.** A key stamped `not_required` was
  created while the age gate was off. If the gate is turned on later, the stamp
  does not excuse the player: the endpoint checks the player's own verification
  and refuses with `age_verification_required` until they verify on the site.
  Both entry writes ask.

## Authentication

Send the key on every request:

```
Authorization: Bearer tmk_...
```

There is no cookie and no CSRF token. The key is accepted only in this header,
not in a query string or a request body. Any user agent is accepted.

```bash
curl -H "Authorization: Bearer $TURF_MONSTER_KEY" https://turfmonster.media/api/v1/me
```

## Errors

Every error from this API, at any status, has one shape:

```json
{ "error": { "code": "invalid_api_key", "message": "That API key is not recognised." } }
```

Branch on `code`. `message` is written for a person and may change.

| Status | `code` | Meaning |
|--------|--------|---------|
| 401 | `missing_api_key` | No `Authorization: Bearer` header |
| 401 | `invalid_api_key` | The key is malformed or unknown |
| 401 | `revoked_api_key` | The player revoked this key |
| 401 | `expired_api_key` | The key is past its 90 days |
| 403 | `account_frozen` | The account is on hold. Every request that is not a `GET` or `HEAD` is refused. Reads still work. |
| 403 | `age_verification_required` | The age gate is on and the player has not verified their date of birth. The player verifies on the site; the same key then works. Returned only by endpoints that enter a contest. |
| 400 | `bad_request` | A required parameter or header is missing, a value is not the type the endpoint takes, or the body is not valid JSON |
| 404 | `not_found` | No such resource. Also `/api` itself and any path under it that is not an endpoint, on any method. |
| 429 | `rate_limited` | Too many requests. The body also carries `retry_after` (seconds), and so does the `Retry-After` header. |
| 500 | `internal_error` | Our fault. Retry shortly. |

A 401 also carries `WWW-Authenticate: Bearer realm="Turf Monster API"`.

The entry writes add their own codes: see [Errors from the entry
endpoints](#errors-from-the-entry-endpoints).

## Rate limits

| Limit | Keyed on |
|-------|----------|
| 120 requests per minute | The API key |
| 600 requests per minute | The calling IP address (a flood backstop) |

Both cover every path under `/api/`.

## Endpoints

### `GET /api/v1/me`

Who the key acts for, and what they can play with. Call it first to confirm the
key works.

```json
{
  "user": { "display_name": "happy-otter", "username": "happy-otter" },
  "wallet": { "kind": "managed", "address": "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd" },
  "free_entry_tokens": 1,
  "account": { "frozen": false },
  "api_key": {
    "prefix": "tmk_a1B2c3",
    "name": "Claude",
    "expires_at": "2026-12-29T18:04:11Z",
    "eligibility": {
      "geo": { "result": "allowed", "country": "US", "state": "CO" },
      "age_gate": "not_required",
      "attested_at": "2026-09-30T18:04:11Z"
    }
  }
}
```

| Field | Notes |
|-------|-------|
| `user.username` | `null` until the player has one |
| `wallet.kind` | `managed`: Turf Monster holds the wallet and signs for the player. `self_custodied`: the player's own wallet must sign. `none`: no wallet yet. |
| `wallet.address` | The player's Solana address, or `null` |
| `free_entry_tokens` | Unspent free entries. **`null` means the balance could not be read just now**, not zero; ask again. |
| `account.frozen` | `true` when the account is on hold |
| `api_key.name` | The label the player gave the key. Always present. |
| `api_key.eligibility.age_gate` | `passed`, or `not_required` when the age gate was off at creation |

This endpoint is read-only, so it answers for a frozen account.

## Reading contests and entries

Five read-only endpoints. Together they tell an agent which contests exist, which
teams it may pick and at what price, and how its player's entries are doing.
None of them changes anything, so all of them answer for a frozen account.

| Route | What it returns |
|-------|-----------------|
| `GET /api/v1/contests` | Open and settled contests |
| `GET /api/v1/contests/:slug` | One contest and the teams you may pick |
| `GET /api/v1/contests/:slug/leaderboard` | Every entry in the contest, ranked |
| `GET /api/v1/entries` | The player's own entries |
| `GET /api/v1/entries/:slug` | One of the player's own entries |

### Conventions

- **Times** are ISO 8601 in UTC (`2026-10-04T17:00:00Z`), or `null` when not set.
- **Money** is integer cents in a field ending `_cents`, with `"currency": "USD"`
  beside it. Entry fees are paid in USDC (one USDC is one dollar) or with a free
  entry token; prizes are paid in USDC.
- **`null` is not zero.** A `team_score` of `null` means no result yet; `0` means
  the team was shut out. A `payout_cents` of `null` means the contest has not
  settled; `0` means it settled and this entry won nothing.
- **The scoring unit depends on the sport.** `scoring_unit` on the contest is
  `"points"` for the NFL and `"goals"` for World Cup soccer. Every `team_score`
  is in that unit.
- **Lists are paged** with `limit` (default 25, maximum 100) and `offset`
  (default 0). A limit above the maximum is clamped, not refused. Every list
  carries `"pagination": { "limit", "offset", "total", "has_more" }`.
- **An invalid parameter value** is a `400` with code `bad_request`, as a missing
  one is: a `status` that is not `open` or `settled`, or a `limit` or `offset`
  that is not a whole number (a word, a negative number, a `limit` of 0, a list,
  or more than nine digits). A blank value is treated as absent. A **slug** is
  different: one that names nothing, or cannot name anything, is a `404`.

### How the game is scored

An entry is a set of teams (`picks_required` of them, normally six). Each pick
earns `team_score × turf_score`, and the entry's `score` is the sum.

- `turf_score` is the team's multiplier. It is fixed when the board is ranked and
  does not move afterwards: the price you see is the price you are paid at.
- `rank` 1 is the strongest offense and carries the lowest multiplier. A higher
  rank number is a weaker offense at a higher multiplier.
- In a contest that spans several weeks (`multi_week: true`) a pick is still one
  team. It scores that team's total across **every** game listed under it, times
  the one `turf_score`. A team with a week off inside the span lists that week in
  `bye_weeks`, plays fewer games, and is priced higher to make up for it.

### `GET /api/v1/contests`

Open and settled contests, newest first. A contest that is still being created
(`pending`) is never listed. A cancelled contest is listed and flagged.

| Parameter | Notes |
|-----------|-------|
| `status` | Optional. `open` or `settled`. Anything else is a `400`. |
| `limit`, `offset` | Paging |

```json
{
  "contests": [
    {
      "slug": "nfl-weeks-4-5-showdown",
      "name": "NFL Weeks 4-5 Showdown",
      "tagline": "Two weeks. Six teams. One board.",
      "game_type": "turf_totals",
      "supported": true,
      "sport": "nfl",
      "scoring_unit": "points",
      "status": "open",
      "phase": "open",
      "locked": false,
      "live": false,
      "settled": false,
      "cancelled": false,
      "coming_soon": false,
      "accepting_entries": true,
      "locks_at": "2026-10-04T17:00:00Z",
      "concludes_at": null,
      "currency": "USD",
      "entry_fee_cents": 1900,
      "guaranteed_prize_cents": 50000,
      "payouts": [
        { "rank": 1, "payout_cents": 30000 },
        { "rank": 2, "payout_cents": 5000 },
        { "rank": 3, "payout_cents": 5000 },
        { "rank": 4, "payout_cents": 5000 },
        { "rank": 5, "payout_cents": 5000 }
      ],
      "max_entries": 29,
      "entries_count": 3,
      "spots_left": 26,
      "picks_required": 6,
      "max_entries_per_player": 3,
      "my_entries_count": 1,
      "multi_week": true,
      "games_per_team": 2,
      "weeks": "Weeks 4-5"
    }
  ],
  "pagination": { "limit": 25, "offset": 0, "total": 1, "has_more": false }
}
```

| Field | Notes |
|-------|-------|
| `slug` | The contest's id in every other route |
| `game_type` | `turf_totals` or `world_cup_survivor` |
| `supported` | `false` for a survivor contest: see [Survivor contests](#survivor-contests) |
| `sport` | `nfl` (American football) or `fifa` (World Cup soccer) |
| `status` | The stored status: `open` or `settled` (`pending` only for an admin key reading one contest). A contest stays `open` after it locks, so read `phase` instead. |
| `phase` | `open`: before the lock. `live`: locked, games being played, not graded. `settled`: graded and final. |
| `locked` | `true` once the lock time has passed. No entry can be made or changed. |
| `live` | `locked` and not yet `settled` |
| `settled` | Graded. Ranks and payouts are final. |
| `cancelled` | The contest was cancelled. It keeps `status: "open"`, so this flag is the only tell. |
| `coming_soon` | Advertised but not ready to play |
| `accepting_entries` | The one-field answer to "would `POST .../entries` get past its gates now": a contest this API can enter (`supported`), open, not locked, not cancelled, not coming soon, a spot left, the player under their own limit, and an account that may write (not on hold; age verified when the age gate is on). It says nothing about the wallet: read `wallet.kind` and `free_entry_tokens` on `GET /api/v1/me` for that. |
| `locks_at` | When the contest locks. Every pick in every entry is final from this moment, including picks whose own game starts later. `null` means no lock is scheduled. An NFL contest locks at 11:00 America/Denver on its opening Sunday (never before its first kickoff), so a Thursday or London game kicks off before it: that team is `locked` from its own kickoff. |
| `concludes_at` | When results are scheduled to be final, if set |
| `guaranteed_prize_cents` | The sum of `payouts` |
| `payouts` | Prize per finishing rank. Ranks not listed win nothing. Tied entries pool the prizes of the places they cover and split them: two entries tied for first share first and second prize. **A paid rank nobody finishes in is not paid.** In a contest that pays five places and has three entries, fourth and fifth prize are not awarded and are not shared among the three. |
| `max_entries`, `entries_count`, `spots_left` | The field's capacity, confirmed entries so far, and the room left (never negative) |
| `picks_required` | Teams per entry |
| `max_entries_per_player` | Entries one player may hold in this contest |
| `my_entries_count` | Confirmed entries this player holds here |
| `multi_week`, `games_per_team`, `weeks` | Whether teams play more than one game in this contest, the most games any team plays, and a label such as `Weeks 4-5` (`null` when the slate has no weeks) |

### `GET /api/v1/contests/:slug`

The contest, in the shape above, plus `teams`: the rows a player may pick, best
rank first. **Only pickable rows are listed.** `matchup_id` is the id an entry is
built from.

```json
{
  "contest": { "slug": "nfl-weeks-4-5-showdown", "...": "as in the list" },
  "teams": [
    {
      "matchup_id": 809431971,
      "team": { "slug": "buffalo-bills", "name": "Buffalo Bills", "short_name": "BUF" },
      "rank": 1,
      "turf_score": 1.0,
      "expected_team_score": 55.0,
      "team_score": null,
      "locked": false,
      "games_count": 2,
      "bye_weeks": [],
      "games": [
        {
          "week": 4,
          "opponent": { "slug": "miami-dolphins", "name": "Miami Dolphins", "short_name": "MIA" },
          "home": true,
          "kickoff_at": "2026-10-04T17:00:00Z",
          "status": "scheduled",
          "started": false,
          "final": false,
          "team_score": null
        },
        {
          "week": 5,
          "opponent": { "slug": "kansas-city-chiefs", "name": "Kansas City Chiefs", "short_name": "KC" },
          "home": false,
          "kickoff_at": "2026-10-11T17:00:00Z",
          "status": "scheduled",
          "started": false,
          "final": false,
          "team_score": null
        }
      ]
    },
    {
      "matchup_id": 809431972,
      "team": { "slug": "miami-dolphins", "name": "Miami Dolphins", "short_name": "MIA" },
      "rank": 5,
      "turf_score": 3.6,
      "expected_team_score": 21.5,
      "team_score": null,
      "locked": false,
      "games_count": 1,
      "bye_weeks": [5],
      "games": [
        {
          "week": 4,
          "opponent": { "slug": "buffalo-bills", "name": "Buffalo Bills", "short_name": "BUF" },
          "home": false,
          "kickoff_at": "2026-10-04T17:00:00Z",
          "status": "scheduled",
          "started": false,
          "final": false,
          "team_score": null
        }
      ]
    }
  ]
}
```

(Four more teams are omitted from the example.)

| Field | Notes |
|-------|-------|
| `matchup_id` | The id of this pick. In a multi-week contest it is the team's first game; the team's later games have no pickable id of their own. |
| `rank` | 1 is the strongest offense. `null` on a board that has not been ranked. |
| `turf_score` | The multiplier. `null` on a board that has not been priced. |
| `expected_team_score` | The projection the ranking was built from, summed over the team's games. Divide by `games_count` to compare a team with a bye against one without. `null` when the board carries no projections (World Cup boards do not). |
| `team_score` | What the team has scored so far across its games in this contest, in the contest's `scoring_unit`. `null` until one of its games has a result. |
| `locked` | `true` when this team can no longer be added to or dropped from an entry: its first game has kicked off, or the contest has locked. |
| `games_count`, `bye_weeks` | Games the team plays in this contest, and the weeks of the span it sits out |
| `games[].week` | `null` when the slate has no weeks |
| `games[].opponent` | `null` if the opponent is not known |
| `games[].home` | `null` if the game is not scheduled |
| `games[].kickoff_at` | `null` if the kickoff is not set |
| `games[].status` | `scheduled`, `in_progress` or `completed` |
| `games[].started` | The kickoff has passed |
| `games[].final` | The game is over |
| `games[].team_score` | This team's score in this game, or `null` |

A `pending` contest is a `404` (an admin's key can read it). An unknown slug is a
`404`.

### `GET /api/v1/contests/:slug/leaderboard`

Every confirmed entry, best first. Takes `limit` and `offset`.

**Other players' picks are hidden until the contest locks.** Before the lock a
rival's row has `"picks_visible": false` and `"picks": null`; the player's own
rows always carry their picks. After the lock every row does.
`picks_hidden_until_lock` says which state the board is in.

Before the lock:

```json
{
  "contest": {
    "slug": "nfl-weeks-4-5-showdown",
    "name": "NFL Weeks 4-5 Showdown",
    "game_type": "turf_totals",
    "phase": "open",
    "locked": false,
    "live": false,
    "settled": false,
    "cancelled": false,
    "locks_at": "2026-10-04T17:00:00Z"
  },
  "supported": true,
  "picks_hidden_until_lock": true,
  "entries": [
    {
      "display_name": "sam_test",
      "mine": true,
      "entry_slug": "sam_test-nfl-weeks-4-5-showdown-980190963",
      "score": 0.0,
      "rank": 1,
      "payout_cents": null,
      "currency": "USD",
      "final": false,
      "picks_visible": true,
      "picks": [ { "matchup_id": 809431971, "...": "six picks, as in an entry" } ]
    },
    {
      "display_name": "jordan_test",
      "mine": false,
      "entry_slug": null,
      "score": 0.0,
      "rank": 1,
      "payout_cents": null,
      "currency": "USD",
      "final": false,
      "picks_visible": false,
      "picks": null
    }
  ],
  "pagination": { "limit": 25, "offset": 0, "total": 3, "has_more": false }
}
```

(A second rival's row, the same shape as the one shown, is omitted from the
example.)

While the games are played (`?limit=2`):

```json
{
  "contest": { "slug": "nfl-weeks-4-5-showdown", "phase": "live", "locked": true, "live": true, "...": "..." },
  "supported": true,
  "picks_hidden_until_lock": false,
  "entries": [
    {
      "display_name": "sam_test",
      "mine": true,
      "entry_slug": "sam_test-nfl-weeks-4-5-showdown-980190963",
      "score": 231.2,
      "rank": 1,
      "payout_cents": null,
      "currency": "USD",
      "final": false,
      "picks_visible": true,
      "picks": [ { "matchup_id": 809431971, "...": "six picks" } ]
    },
    {
      "display_name": "casey_test",
      "mine": false,
      "entry_slug": null,
      "score": 231.2,
      "rank": 1,
      "payout_cents": null,
      "currency": "USD",
      "final": false,
      "picks_visible": true,
      "picks": [ { "matchup_id": 809431971, "...": "six picks" } ]
    }
  ],
  "pagination": { "limit": 2, "offset": 0, "total": 3, "has_more": true }
}
```

| Field | Notes |
|-------|-------|
| `display_name` | The player's public name |
| `mine` | This row is one of the calling player's entries |
| `entry_slug` | The entry's id for `GET /api/v1/entries/:slug`. Only on the player's own rows; `null` on a rival's. |
| `score` | Sum of the entry's pick points |
| `rank` | Tied scores share a rank and the next rank skips: 1, 1, 3. While `final` is `false` it is the standing on current scores and will move. |
| `payout_cents` | `null` until the contest settles. Then the amount this entry won, `0` included. |
| `final` | `true` once the contest has settled: `rank` and `payout_cents` will not change. |
| `picks_visible`, `picks` | See above. Each pick has the shape described under [entries](#get-apiv1entries). |

`rank` is the entry's rank in the whole contest, whatever page it is on.

### `GET /api/v1/entries`

The player's own entries, newest first.

| Parameter | Notes |
|-----------|-------|
| `contest` | Optional contest slug. An unknown slug is a `404`. |
| `limit`, `offset` | Paging |

**Which entries.** Submitted ones: `active` (the contest has not been graded)
and `complete` (it has). An unfinished lineup saved on the website (a cart) and
an abandoned one are not entries and are never returned, here or by slug.

```json
{
  "entries": [
    {
      "slug": "sam_test-nfl-weeks-4-5-showdown-980190963",
      "contest": {
        "slug": "nfl-weeks-4-5-showdown",
        "name": "NFL Weeks 4-5 Showdown",
        "game_type": "turf_totals",
        "phase": "live",
        "locked": true,
        "live": true,
        "settled": false,
        "cancelled": false,
        "locks_at": "2026-10-04T17:00:00Z"
      },
      "status": "active",
      "entry_number": 0,
      "submitted_at": "2026-10-01T15:00:00Z",
      "tx_signature": "4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi5Yq1mCQXxkzLkzTTDxvQyhU2r8PZs2cRUXAMPLE",
      "editable": false,
      "score": 231.2,
      "rank": 1,
      "payout_cents": null,
      "currency": "USD",
      "final": false,
      "picks_visible": true,
      "picks": [
        {
          "matchup_id": 809431971,
          "team": { "slug": "buffalo-bills", "name": "Buffalo Bills", "short_name": "BUF" },
          "rank": 1,
          "turf_score": 1.0,
          "expected_team_score": 55.0,
          "team_score": 31,
          "locked": true,
          "games_count": 2,
          "bye_weeks": [],
          "games": [
            {
              "week": 4,
              "opponent": { "slug": "miami-dolphins", "name": "Miami Dolphins", "short_name": "MIA" },
              "home": true,
              "kickoff_at": "2026-10-04T17:00:00Z",
              "status": "completed",
              "started": true,
              "final": true,
              "team_score": 31
            },
            {
              "week": 5,
              "opponent": { "slug": "kansas-city-chiefs", "name": "Kansas City Chiefs", "short_name": "KC" },
              "home": false,
              "kickoff_at": "2026-10-11T17:00:00Z",
              "status": "scheduled",
              "started": false,
              "final": false,
              "team_score": null
            }
          ],
          "points": 31.0
        },
        {
          "matchup_id": 809431972,
          "team": { "slug": "miami-dolphins", "name": "Miami Dolphins", "short_name": "MIA" },
          "rank": 5,
          "turf_score": 3.6,
          "expected_team_score": 21.5,
          "team_score": 17,
          "locked": true,
          "games_count": 1,
          "bye_weeks": [5],
          "games": [ { "week": 4, "...": "as above" } ],
          "points": 61.2
        }
      ]
    }
  ],
  "pagination": { "limit": 25, "offset": 0, "total": 1, "has_more": false }
}
```

(Four more picks are omitted from the example, which shows the entry as it
reads while its contest is live.)

| Field | Notes |
|-------|-------|
| `slug` | The entry's id |
| `contest` | A short form of the contest. Fetch `GET /api/v1/contests/:slug` for the rest. |
| `status` | `active` or `complete` |
| `entry_number` | The index of the player's slot in this contest that the entry holds on chain. `null` if it has none. |
| `submitted_at` | When the entry was created |
| `tx_signature` | The Solana transaction that paid for the entry, or `null` |
| `editable` | `true` while `PATCH /api/v1/entries/:slug` would be accepted: the entry is active, its contest is open, not cancelled and not locked, and the account may write (not on hold; age verified when the age gate is on). Even then, a pick whose own `locked` is `true` cannot be swapped out, and a locked team cannot be swapped in. |
| `score`, `rank`, `payout_cents`, `final` | As on the leaderboard |
| `picks` | One per team picked, best rank first. Each is the team row from the contest detail plus `points`. |
| `picks[].points` | What the pick has earned: `team_score × turf_score`. `null` until the team has a result. |

### `GET /api/v1/entries/:slug`

One entry, in the same shape, under an `entry` key:

```json
{ "entry": { "slug": "sam_test-nfl-weeks-4-5-showdown-980190963", "...": "as in the list" } }
```

Another player's entry is a `404`, the same answer as a slug that does not exist.
Read rivals through the leaderboard.

### Survivor contests

World Cup Survivor (`game_type: "world_cup_survivor"`) is played in rounds, one
team per round, and is not served by this API yet. A survivor contest is listed
so an agent knows it exists, and marked so it is not mistaken for a contest it
can play:

- in the list and the detail it has `"supported": false` and a `note`;
- its detail has `"teams": []`;
- its leaderboard has `"supported": false`, a `note` and `"entries": []`;
- an entry in one is returned with `"picks_visible": false` and `"picks": null`.

### Errors from these endpoints

| Status | `code` | When |
|--------|--------|------|
| 400 | `bad_request` | `status` is not `open` or `settled`; `limit` or `offset` is not a whole number |
| 401 | the four key errors above | No key, or a bad, revoked or expired one |
| 404 | `not_found` | Unknown contest or entry slug; a `pending` contest; another player's entry; a cart or abandoned entry; a path that is not an endpoint |
| 429 | `rate_limited` | The limits above apply to every route here |

```json
{ "error": { "code": "bad_request", "message": "status must be one of: open, settled." } }
```

### For developers: the read endpoints

| Piece | Where |
|-------|-------|
| Routes (drawn from their own file so `config/routes.rb` line numbers hold) | `config/routes/api_v1.rb` |
| The actions (each names an operation and renders its outcome) | `app/controllers/api/v1/contests_controller.rb`, `entries_controller.rb`, `me_controller.rb` |
| The work: queries, visibility, parameter checks. One class per endpoint, shared with the MCP tools | `app/services/api/v1/operations/` |
| Paging | `app/controllers/api/v1/pagination.rb` |
| Contest JSON | `app/serializers/api/v1/contest_serializer.rb` |
| Entry and leaderboard-row JSON | `app/serializers/api/v1/entry_serializer.rb` |
| Team rows and picks, from one load of the slate | `app/serializers/api/v1/board.rb` |
| Slate facts for a page of contests in two queries (mirrors `Contest`; the test holds the two together) | `app/serializers/api/v1/contest_facts.rb` |
| Tie-aware rank before a contest settles (the rule `Contest#grade!` applies) | `app/serializers/api/v1/ranking.rb` |
| The web's visibility and capacity rules, reused as written | `app/serializers/api/v1/web_rules.rb` wrapping `ContestsHelper` |

The serializers are plain objects that return hashes, so another surface (the
MCP endpoint) can return the same shapes without going through a controller.

## Entering a contest

Two endpoints. One creates an entry and pays for it; the other replaces the
picks of an entry the player already holds.

| Route | What it does |
|-------|--------------|
| `POST /api/v1/contests/:slug/entries` | Create an entry from six teams and pay for it, in one call |
| `PATCH /api/v1/entries/:slug` | Replace the picks of one of the player's entries, before the contest locks |

Both take a JSON body (`Content-Type: application/json`) and both are refused
for an account on hold (`403 account_frozen`) and, when the age gate is on, for
a player who has not verified their date of birth (`403
age_verification_required`).

**An entry spends something that cannot be given back.** A free entry token is
consumed on Solana, or USDC is transferred, in the same call that creates the
entry. Read [Retrying safely](#retrying-safely) before you write a retry loop.

**Who can enter through the API.** A player whose wallet Turf Monster holds and
signs for: `wallet.kind` is `managed` on `GET /api/v1/me`. A self-custodied
wallet, an account with a Phantom wallet linked, and an account with no wallet
are refused with `wallet_not_server_signable`; those players enter on the
website, where their own wallet signs.

**There is no cart.** The website saves a lineup one tap at a time and submits
it later. The API does neither: an entry is created whole and paid for in one
call, or it is not created. The player's unfinished lineup on the website is
never read, changed or submitted by an API call, and an API entry does not pass
through the website's cart.

### `POST /api/v1/contests/:slug/entries`

| Field | Where | Notes |
|-------|-------|-------|
| `Idempotency-Key` | header | **Required.** A value you make up for this entry, 1 to 255 printable characters with no spaces (a UUID is ideal). Send the same value on every retry of the same entry. |
| `matchup_ids` | body | **Required.** A list of exactly `picks_required` different ids, each a `teams[].matchup_id` from `GET /api/v1/contests/:slug`. Order does not matter. |
| `allow_usdc` | body | Optional, default `false`. A JSON boolean: `true` or `false`. The strings `"true"` and `"false"` are a `400`. See below. |

**Token only, unless you say otherwise.** By default an entry is paid for with
one of the player's free entry tokens, and if the player has none the request
is refused with `no_entry_token` and nothing is spent. Send `"allow_usdc": true`
to let the entry fee be paid in USDC from the player's wallet when there is no
token. A token is still used first when there is one. Only send it when the
player has told you to spend money.

```bash
curl -X POST https://turfmonster.media/api/v1/contests/nfl-weeks-4-5-showdown/entries \
  -H "Authorization: Bearer $TURF_MONSTER_KEY" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: 7f0c1b9e-3c1d-4a55-9d53-0f2a6a1f7c11" \
  -d '{"matchup_ids": [809431971, 809431972, 809431973, 809431974, 809431975, 809431976]}'
```

`201 Created`:

```json
{
  "entry": {
    "slug": "sam_test-nfl-weeks-4-5-showdown-980190984",
    "contest": {
      "slug": "nfl-weeks-4-5-showdown",
      "name": "NFL Weeks 4-5 Showdown",
      "game_type": "turf_totals",
      "phase": "open",
      "locked": false,
      "live": false,
      "settled": false,
      "cancelled": false,
      "locks_at": "2026-10-04T17:00:00Z"
    },
    "status": "active",
    "entry_number": 0,
    "submitted_at": "2026-10-01T15:00:00Z",
    "tx_signature": "4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi5Yq1mCQXxkzLkzTTDxvQyhU2r8PZs2cRUXAMPLE",
    "editable": true,
    "score": 0.0,
    "rank": 3,
    "payout_cents": null,
    "currency": "USD",
    "final": false,
    "picks_visible": true,
    "picks": [ { "matchup_id": 809431971, "...": "six picks, as in GET /api/v1/entries" } ]
  },
  "funding": { "method": "token", "token_consumed": true }
}
```

| Field | Notes |
|-------|-------|
| `entry` | The new entry, exactly as `GET /api/v1/entries/:slug` returns it |
| `funding.method` | `token`: a free entry token was spent. `usdc`: the entry fee was paid in USDC. `free`: the contest has no entry fee. `unknown`: the entry was recovered after a lost response (see below) on a request that allowed USDC, so which of the two paid was not recorded; read the wallet to tell. |
| `funding.token_consumed` | `true` when a token was spent, `false` when not, `null` when `method` is `unknown` |

**`202 Accepted` means paid and not yet visible.** Rarely, the payment lands on
Solana and the write that marks the entry active fails. The entry is paid for
and will be completed; it is not listed yet.

```json
{ "entry": null, "funding": { "method": "token", "token_consumed": true }, "pending": true, "retry_after": 5 }
```

Send the same request with the same `Idempotency-Key` after `retry_after`
seconds. It returns `201` with the entry and spends nothing more. Do not send a
new key: the entry already exists.

**A `202` can persist.** If the reason the entry could not be marked active is a
rule rather than a hiccup (the contest locked or filled in the seconds the
payment took), every retry answers `202` and nothing completes it on its own.
After a few minutes of `202`s, stop retrying and tell the player plainly: the
entry was paid for, it is not showing as entered, and they should contact
support@turfmonster.media with the contest name. Do not enter again with a new
key.

### `PATCH /api/v1/entries/:slug`

Replaces all of the entry's picks. It is not a spend: nothing moves on Solana,
and no `Idempotency-Key` is needed, because sending the same picks twice leaves
the same entry.

| Field | Where | Notes |
|-------|-------|-------|
| `matchup_ids` | body | **Required.** The full new lineup: exactly `picks_required` different ids from the contest's `teams[].matchup_id`. |

Allowed only while the entry's `editable` is `true`: before the contest locks.
Within that, **a team whose first game has kicked off can be neither added nor
dropped** (its `locked` is `true`). A locked team already in the lineup may stay,
and the other picks may still change around it. The new lineup may not match
another entry the player holds in the same contest.

```bash
curl -X PATCH https://turfmonster.media/api/v1/entries/sam_test-nfl-weeks-4-5-showdown-980190984 \
  -H "Authorization: Bearer $TURF_MONSTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"matchup_ids": [809431971, 809431972, 809431973, 809431974, 809431975, 809431977]}'
```

`200 OK`:

```json
{ "entry": { "slug": "sam_test-nfl-weeks-4-5-showdown-980190984", "editable": true, "...": "the entry, with its new picks" } }
```

### Errors from the entry endpoints

Every one is in the usual envelope. `message` says what happened in words; for
`team_locked`, `invalid_picks`, `entry_limit_reached` and `contest_full` it
names the team or the number. **Unless a row says otherwise, nothing was
spent.**

```json
{ "error": { "code": "no_entry_token", "message": "This account holds no free entry token, and USDC was not allowed. Nothing was spent. Send allow_usdc: true to pay the entry fee in USDC instead." } }
```

| Status | `code` | From | Meaning | What the agent should do |
|--------|--------|------|---------|--------------------------|
| 400 | `bad_request` | both | No `Idempotency-Key` (POST), a key that is too long or has spaces, `matchup_ids` missing or not a list of ids, `allow_usdc` not a JSON `true` or `false`, a body that is not JSON | Fix the request. It was not recorded, so the same key is still unused. |
| 401 | the four key errors | both | No key, or a bad, revoked or expired one | Ask the player for a working key. |
| 403 | `account_frozen` | both | The account is on hold | Stop. Tell the player to contact support. |
| 403 | `age_verification_required` | both | The age gate is on and the player has not verified | Tell the player to verify their date of birth on the website, then retry with the same key. |
| 404 | `not_found` | both | No such contest (POST), or no such entry among the player's own (PATCH) | Re-read `GET /api/v1/contests` or `GET /api/v1/entries`. |
| 409 | `idempotency_key_reused` | POST | This key is already tied to something else: a request with different picks, a different contest or a different `allow_usdc`, or an entry that no longer exists. A contest reset voids every finished key used on that contest (`Contest#reset!`, `ApiEntryRequest.void_for_reset!`), and `Entries::ApiSubmission#replay` refuses any key whose entry row is gone, so a stored `201` is never returned for a deleted entry. | Stop sending this request with this key; the answer does not change, and the key never enters again. If the body was changed by mistake, send the original body once. If the body was already the original, the key is finished: read the player's entries, and make a new entry only with a new key and the player's yes. See "After a contest reset" below for what that new entry costs. |
| 409 | `idempotency_in_progress` | POST | A request to enter this contest is still running for this player: this key's first request, or another key's | Wait `retry_after` seconds and send the same request again. Do not switch keys. |
| 422 | `contest_not_open` | both | The contest is settled, or is not ready to take entries | Pick another contest. |
| 422 | `contest_locked` | both | The lock time has passed | Nothing to do; entries and edits are closed. |
| 422 | `contest_cancelled` | both | The contest was cancelled | Pick another contest. |
| 422 | `coming_soon` | POST | The contest is advertised but not open for entries yet | Try again when `coming_soon` is `false`. |
| 422 | `unsupported_contest` | both | A survivor contest (`supported: false`) | Send the player to the website. |
| 422 | `contest_full` | POST | No spots left | Pick another contest. |
| 422 | `entry_limit_reached` | POST | The player already holds `max_entries_per_player` entries here | Edit an existing entry instead. |
| 422 | `invalid_picks` | both | Not exactly `picks_required` different ids, or an id that is not one of this contest's `teams[].matchup_id` | Re-read the contest and rebuild the lineup. For POST, send it with a **new** key (the old key is tied to the old picks). |
| 422 | `duplicate_lineup` | both | The player already holds an entry with exactly these teams in this contest | Change at least one team. For POST, with a new key. |
| 422 | `team_locked` | both | A team in the request has kicked off (POST), or the edit adds or drops one that has (PATCH) | Choose teams whose `locked` is `false`. For POST, with a new key. |
| 422 | `no_entry_token` | POST | No free entry token, and `allow_usdc` was not `true` (or USDC entry is switched off) | Tell the player. Only with their say-so, retry with `allow_usdc: true`, which needs a new key because the body changed. |
| 422 | `insufficient_funds` | POST | `allow_usdc` was `true`, there is no token, and the wallet does not hold the entry fee in USDC | Tell the player to add funds. The same key works once they have. |
| 422 | `wallet_not_server_signable` | POST | The wallet is self-custodied or Phantom-linked, or there is no wallet | Send the player to the website. The API cannot enter for this account. |
| 503 | `chain_unavailable` | POST | Solana could not be read, or did not confirm the payment in time. **The payment may or may not have landed.** | Wait `retry_after` seconds and send the same request with the **same** key. The server looks for the payment before it pays again; see [Retrying safely](#retrying-safely) for exactly what that covers. |
| 500 | `internal_error` | both | Our fault | Retry with the same key. |

`idempotency_in_progress`, `503` and `202` responses carry `retry_after`
(seconds) in the body and as a `Retry-After` header.

### Retrying safely

The rule: **one entry, one `Idempotency-Key`, and never change the key because
a request failed.** Make the key when you decide to enter, keep it until you
hold a `201` or a `422`, and reuse it on every attempt in between.

A key belongs to the player, not to the API key, and it does not expire. The
same key with the same contest, the same teams (in any order) and the same
`allow_usdc` is the same request.

| What you got | What it means | What to send next |
|--------------|---------------|-------------------|
| `201` | The entry exists | Nothing. Sending the request again returns the same `201`, byte for byte, with the header `Idempotent-Replayed: true`, for as long as the entry exists. It is the first response: it does not reflect later edits. If the entry has been removed (a contest reset), the key answers `409 idempotency_key_reused` instead. |
| `202` | Paid, being confirmed | The same request, same key, after `retry_after`. |
| `409 idempotency_in_progress` | Your first request is still running | The same request, same key, after `retry_after`. |
| `503 chain_unavailable` | Unknown: the payment may have landed | The same request, same key, after `retry_after`. If it landed, you get the entry it paid for. If it did not, the server waits until it no longer can before paying again, so you may see more `503`s for up to about five minutes. |
| No response at all (timeout, dropped connection) | Unknown | The same request, same key. This is the case the key exists for. |
| `422` | Refused, nothing spent | If the cause can change without changing the body (a token arrives, funds are added, a spot opens), the same key works. If you change the picks or `allow_usdc`, use a new key. |
| `400`, `401`, `403`, `404` | Not recorded | Fix the cause. The key is still unused. |
| `500` | Our fault | The same request, same key. |

Giving up on a key after a `503` and sending a new one does not get around
this, and is not a way to pay twice: before any request for a contest is allowed
to spend, an earlier unresolved one for the same player and contest is settled
first. While the earlier payment is still unknown the new request answers `503`
too. If the earlier payment turns out to have landed, it becomes the earlier
key's entry, and a new request for the same teams is then a `duplicate_lineup`.

**What this guarantees, and the one thing it does not.** A retry with the same
key replays a finished entry, waits on one in progress, and looks on Solana for
a paid entry before it pays. It does not pay again unless the earlier payment
was refused by the program, or 150 seconds have passed with no trace of it on
chain. The case it cannot see: a server process killed in the middle of sending
a payment, more than four minutes into a request, while a retry of the same key
is already waiting behind it. That needs a stalled network and a crash at the
same moment; it is why this page says "looks before it pays" and not "can never
pay twice".

`PATCH` needs none of this. Repeat it freely.

#### What the server keeps

One record per player and key, in one of six states. This is what the table
above is a view of.

| State | Meaning | A request with this key |
|-------|---------|-------------------------|
| `executing` | A request is running now | `409 idempotency_in_progress`. After two minutes with no result the request is taken to have died, and the key is treated as `uncertain`. A request that is in fact still alive past that point checks, immediately before it pays, that it still owns the key, and stops if a retry has taken over. |
| `failed` | The last attempt ended and spent nothing, with certainty. Either it was refused before the payment was sent, or the payment was sent and the Turf Monster program itself refused it (a failed simulation naming a program error, or a transaction that landed and failed). No other failure after the payment is sent counts: a timeout, a dropped connection, and a node answering "already been processed" or "already in use" are all `uncertain`. | Runs again from the top. Even then it looks on Solana for a paid entry before building a new one. |
| `uncertain` | The payment was sent and its outcome is not known | Looks on Solana first. A paid entry found there becomes this key's entry (`201`). Otherwise `503` for 150 seconds after the attempt ended, and only then runs again. The 150 seconds is a wall-clock margin over the 60 to 90 seconds a Solana transaction stays valid; it is not read from the transaction's own expiry. |
| `confirming` | Paid; the entry is on file and not yet active | Finishes it and returns `201`, or `202` again. A background job finishes it too, so the entry appears even if the agent never returns. |
| `succeeded` | Done | Replays the stored `201` while the entry exists. If the entry row has been deleted, `409 idempotency_key_reused`. |
| `void` | The contest was reset after this request finished. The record holds no entry and no stored response. | `409 idempotency_key_reused`, every time, for any body. Nothing runs and nothing is spent. |

Only one request per player and contest runs at a time, whatever its key.

#### After a contest reset

`Contest#reset!` (the admin Reset, and what a QA rehearsal runs between passes)
deletes every entry row of the contest. It touches nothing on chain: each paid
entry's ticket (its `ContestEntry` account) is still there, and a token it
consumed stays consumed. Nothing is refunded.

In the same transaction the reset voids the contest's finished requests:

| State at reset | After | Why |
|----------------|-------|-----|
| `succeeded`, `confirming` | `void`, with the entry pointer and the stored response cleared | Both are paid and landed, and their entry rows were just deleted. A stored `201` would describe an entry that does not exist. |
| `executing`, `uncertain` | Unchanged | A payment may still be in flight. The record and its clock are what make every later request for the contest wait for it. It holds no `201` to replay. |
| `failed` | Unchanged | It spent nothing and holds no response. A retry is the request the player never got an entry for. |

**The old key, afterwards: `409 idempotency_key_reused`, for good.** The
alternatives were worse. Replaying the `201` tells the agent its player holds an
entry that is gone. Deleting the record makes the old key a fresh request, so a
retry loop still running from before the reset would enter the player again
with nobody having asked. A void key runs nothing.

**A new key, afterwards, is a new request.** Before it builds an entry it looks
on Solana for a paid ticket of this player's that no entry row holds
(`Entries::ApiSubmission#build_entry`), finds the one the reset left, and builds
the new entry on it: no second token, no second fee. Only when no such ticket is
found is the entry paid for again. One wrinkle, unchanged by this: the token
check runs before that lookup, so an account with no unspent token and no
`allow_usdc` is answered `no_entry_token` without the ticket being looked for.

### For developers: the entry endpoints

| Piece | Where |
|-------|-------|
| Routes | `config/routes/api_v1.rb` |
| The two actions | `app/controllers/api/v1/entries_controller.rb` |
| The header and body checks, and the edit's two extra rules | `app/services/api/v1/operations/submit_entry.rb`, `edit_entry.rb` |
| Strict parameter readers (a wrong shape is a 400, not a 500) | `app/controllers/api/v1/strict_params.rb` |
| Create, at most once per key: the claim, settling a doubt, the gates that need no entry, the response | `app/services/entries/api_submission.rb` |
| The idempotency record, its states and its two clocks | `app/models/api_entry_request.rb` |
| Gate, pay, confirm: the path the website's Enter button also takes | `app/services/entries/managed_entry.rb` |
| A refusal with a code (`Entry::Refusal`) | `app/models/entry/refusal.rb`, raised by `Entry#assert_enterable!` and `#update_picks!` |
| Seeds, level-up and navbar caches after a confirmed entry | `app/services/entries/post_entry_effects.rb` |
| Converging a paid entry that did not finish | `Entries::OnchainReconcileJob`, `Entries::OnchainReconciler` |
| The 404 for an unknown `/api/` path | `app/controllers/api/v1/errors_controller.rb`, the last route in the `namespace :api` block |
| The decision tree, with the browser's path beside it | [`docs/workflows/submit-entry-decision-tree.md`](workflows/submit-entry-decision-tree.md) §2 and §2a |

`Entries::ApiSubmission` takes a player, a contest, picks and a key and returns
a status and a body, so another surface (the MCP endpoint) can create an entry
through the same record without going through this controller.

Known gap: nothing sweeps `uncertain` records. A payment that landed for a
request whose agent never came back stays an unclaimed ticket until the same
player sends another request for that contest, or an operator looks.

## MCP

The same API as a remote [Model Context Protocol](https://modelcontextprotocol.io)
server, for a client that cannot make HTTP requests of its own but can use an
MCP connector. Eight tools, one per endpoint above. Each tool runs the same code
as its endpoint, so everything on this page about rules, errors and retries
holds for the tools as written.

| | |
|---|---|
| Endpoint | `POST https://turfmonster.media/mcp` |
| Transport | MCP Streamable HTTP. Every request is answered with one `application/json` body. No event stream, no session. |
| Protocol revisions | `2025-03-26`, `2025-06-18`, `2025-11-25`. Not `2026-07-28`, the current one: see [Protocol notes](#protocol-notes). |
| Authentication | `Authorization: Bearer tmk_...` on every request, `initialize` included |
| Methods | `initialize`, `ping`, `tools/list`, `tools/call`, and any notification |

### Connecting a client

What works today, and what does not. "Verified" means read in the vendor's own
documentation on 2026-10-01, at the link given; see also [Clients
tested](#clients-tested).

| Client | Works with a key today? | How |
|--------|-------------------------|-----|
| **Claude Code** (terminal, desktop app, IDE) | **Yes** | The command or the file below |
| Any MCP client that can send a request header (the MCP Inspector, an SDK client, Cursor and similar) | **Yes** | Streamable HTTP to `/mcp` with the `Authorization` header |
| **claude.ai, Claude Desktop and Claude mobile, as a custom connector** | **Not for most accounts** | A custom connector signs in with OAuth, which this server does not offer yet. Sending a fixed header instead ("Request headers", under *Add custom connector*) is, in Anthropic's words, "in beta and available to a limited set of organizations". An account that has that section can connect: choose **No sign-in**, add the header `authorization` with the value `Bearer tmk_...` (the word `Bearer`, a space, then the key). An account that does not have it cannot connect until Turf Monster adds OAuth. Source: [Add a connector that isn't in the directory](https://claude.com/docs/connectors/custom/add-unlisted), "Authenticate with request headers". |

A claude.ai connector added without a header gets a `401` and reports that it
could not connect. That is the missing OAuth, not a fault in the key.

**Claude Code**, from a terminal
([docs](https://code.claude.com/docs/en/mcp)):

```bash
claude mcp add --transport http turf-monster https://turfmonster.media/mcp \
  --header "Authorization: Bearer tmk_..."
```

That stores the key in your own Claude Code settings (`~/.claude.json`), for the
current project. Add `--scope user` to have it in every project. Then run
`/mcp` inside Claude Code to see the eight tools.

To keep the key out of a file you share, use a project `.mcp.json` that reads
it from the environment:

```json
{
  "mcpServers": {
    "turf-monster": {
      "type": "http",
      "url": "https://turfmonster.media/mcp",
      "headers": { "Authorization": "Bearer ${TURF_MONSTER_KEY}" }
    }
  }
}
```

**Never put the key in the URL.** `/mcp?key=...` is not read, on purpose: URLs
end up in logs and histories.

### The tools

| Tool | Same as | Arguments | Changes anything? |
|------|---------|-----------|-------------------|
| `get_me` | `GET /api/v1/me` | none | No |
| `list_contests` | `GET /api/v1/contests` | `status` (`open` or `settled`), `limit`, `offset` | No |
| `get_contest` | `GET /api/v1/contests/:slug` | **`contest_slug`** | No |
| `get_leaderboard` | `GET /api/v1/contests/:slug/leaderboard` | **`contest_slug`**, `limit`, `offset` | No |
| `list_my_entries` | `GET /api/v1/entries` | `contest_slug`, `limit`, `offset` | No |
| `get_entry` | `GET /api/v1/entries/:slug` | **`entry_slug`** | No |
| `submit_entry` | `POST /api/v1/contests/:slug/entries` | **`contest_slug`**, **`matchup_ids`**, **`idempotency_key`**, `allow_usdc` (default `false`) | **Yes: spends a token, or USDC** |
| `edit_entry` | `PATCH /api/v1/entries/:slug` | **`entry_slug`**, **`matchup_ids`** | Yes: replaces the picks |

Bold arguments are required. `tools/list` returns each tool's full JSON Schema
and a description written for the model. No tool takes an argument that is not
listed: an unknown one is refused, by name, so a model that sends `slug` for
`contest_slug` is told so.

`idempotency_key` is the `Idempotency-Key` header of the REST endpoint, moved
into the arguments because a model cannot set a header. It is the same record:
a key used over MCP replays over REST, and the other way round. Everything in
[Retrying safely](#retrying-safely) applies.

Each tool carries annotations a client may use to decide when to ask the
player first: the six reads are `readOnlyHint: true`; `submit_entry` and
`edit_entry` are `readOnlyHint: false` and `destructiveHint: true` (one spends
what cannot be returned, the other overwrites). All eight are
`idempotentHint: true` and `openWorldHint: false`.

The `initialize` result carries `instructions` for the model: what the game is,
the order to call the tools in, to confirm the lineup with the player before
submitting, to leave `allow_usdc` off unless the player says otherwise, and the
one-entry-one-key retry rule.

### Results and errors

A tool result is the REST response body, unchanged:

```json
{
  "content": [{ "type": "text", "text": "{\"entry\":{...},\"funding\":{...}}" }],
  "structuredContent": { "entry": { }, "funding": { "method": "token", "token_consumed": true } },
  "isError": false,
  "_meta": { "turfmonster.media/http_status": 201 }
}
```

| Part | What it holds |
|------|---------------|
| `content[0].text` | The REST body as a JSON string. Always present. |
| `structuredContent` | The same body as JSON. Sent when the request carries `MCP-Protocol-Version: 2025-06-18` or later; revision `2025-03-26` has no such field. |
| `isError` | `true` when REST would answer 4xx or 5xx. The body is then the usual envelope, `{ "error": { "code", "message" } }`, with the same codes as the tables above. |
| `_meta` | What REST says in its status line and headers: `turfmonster.media/http_status`, `turfmonster.media/retry_after` (seconds), `turfmonster.media/idempotent_replayed` (`true` on a replay). |

Three answers from `submit_entry` are worth knowing by sight:

| REST | As a tool result | What to do |
|------|------------------|------------|
| `202`, `"pending": true` | `isError: false`, the same body, and a second text block that begins `PENDING: PAID, NOT YET ENTERED` | The entry is paid but not confirmed. Call again with the same `idempotency_key` after `retry_after` seconds. Do not tell the player they are entered until a call returns an entry; after a few minutes of `pending`, stop and send them to support. |
| `409 idempotency_in_progress` | `isError: true`, a second text block that begins `RETRY` | Call again with the same key after `retry_after` seconds. |
| `503 chain_unavailable` | `isError: true`, a second text block that begins `RETRY` | The same. Never switch keys. |

Some failures are not tool results, because they are not about a tool:

| Failure | Answer |
|---------|--------|
| No key, or a bad, revoked or expired one | HTTP `401` with `WWW-Authenticate: Bearer realm="Turf Monster API"` and the REST envelope. No JSON-RPC is read first. |
| Too many requests | HTTP `429` with `Retry-After` and the REST envelope (`rate_limited`) |
| A body that is not JSON | HTTP `400`, JSON-RPC error `-32700` |
| Not a JSON-RPC request; an `MCP-Protocol-Version` this server does not speak; a batch sent at a revision without batches | HTTP `400`, JSON-RPC error `-32600` |
| A method other than the four above | JSON-RPC error `-32601` |
| An unknown tool, or `arguments` that is not an object | JSON-RPC error `-32602` |
| A crash on our side | JSON-RPC error `-32603`. For `submit_entry`, retry with the same key. |
| `GET`, `DELETE`, `PUT` or `PATCH /mcp` | HTTP `405`, `Allow: POST`, JSON-RPC error `-32600` |
| A request with an `Origin` header that is not this site's (a web page calling) | HTTP `403` |

An argument of the wrong type is a tool result (`isError: true`, code
`bad_request`), not a JSON-RPC error, so the model can read it and try again.

An account on hold, or short of the age gate, can call every read tool. The two
writing tools answer `account_frozen` or `age_verification_required`.

### Limits

| Limit | Keyed on |
|-------|----------|
| 120 requests per minute | The API key. Separate from the key's 120 on `/api/`. A JSON-RPC batch counts once per message. |
| 30 requests per minute (300 from Anthropic's connector addresses) | The calling IP address, for requests with no key, **or with a key that has not yet authenticated here**. A key's first successful request takes it out of this limit for 24 hours. |

A player is never limited by the address they call from, only by their key, so
claude.ai players who share Anthropic's addresses cannot lock each other out.

Also: a request body is at most 64 KB, and a JSON-RPC batch (revision
`2025-03-26` only) holds at most 10 messages. A batch that would take the key
past its 120 is refused whole with a `429` and runs nothing. Detail and the
reasoning: [`RATE_LIMITING.md`](RATE_LIMITING.md).

### Protocol notes

- **Stateless.** No `MCP-Session-Id` is issued and nothing is remembered from
  `initialize`. The revision a client negotiated reaches later requests in the
  `MCP-Protocol-Version` header. Without that header the server assumes
  `2025-03-26`, as the specification says to.
- **Version negotiation.** `initialize` answers with the client's revision when
  it is one of the three, and with `2025-11-25` otherwise. Any other value in
  the `MCP-Protocol-Version` header of a later request is a `400`.
- **Revision `2026-07-28` is not spoken.** It is the current revision and it
  removes the `initialize` handshake: every request carries its version in
  `params._meta`, and a server answers `server/discover`. A client that speaks
  both eras tries that first and falls back to `initialize` when it gets a `400`
  that is not one of the new error codes (`-32020` to `-32022`). That is what
  this server returns, and the fallback is what Claude Code does against it
  (see [Clients tested](#clients-tested)); it costs one extra request per
  connection. A client that speaks **only** `2026-07-28` cannot connect. Serving
  it natively is a small piece of work, because this server is already
  stateless, and has not been done.
- **Batches** are accepted at `2025-03-26` only. `2025-06-18` removed them from
  the protocol. `initialize` may not be part of one.
- **Capabilities:** `tools` only. No resources, prompts, logging or completions.
- **No library.** The server is about 600 lines, comments included, in `app/services/agent_mcp/`.
  The `mcp` gem is in the lockfile only as a development dependency of rubocop.
  It is not in the production bundle, and its transport is built around
  sessions and event streams this endpoint does not have.

### Clients tested

Run against a local stack on 2026-10-01, with a real key.

| Client | Result |
|--------|--------|
| **Claude Code 2.1.286**, headless (`claude -p --mcp-config`), with the `.mcp.json` shape above and the key from an environment variable | Connected, listed all eight tools, and called `get_me`, `list_contests` and `get_contest`, answering from their results. Its first request was a `server/discover` probe at revision `2026-07-28`; it got the `400` and fell back to `initialize` at `2025-11-25`. Its `GET /mcp` got the `405` and it carried on. |
| **MCP Inspector 2.9.0**, command line (`npx @modelcontextprotocol/inspector --cli … --header "Authorization: Bearer …"`) | `tools/list --strict` reported no schema portability problems. `tools/call` returned `structuredContent` and the text block for `get_me` and `get_contest`; a wrong argument name came back as `isError: true` with `bad_request`. Without a key it read the `401` as "sign in with OAuth", which this server does not offer. |
| **Claude Code 2.1.286**, the command `/agents` shows, run as printed with a desk address and a real desk key, under a throwaway `CLAUDE_CONFIG_DIR` | `claude mcp add` stored the server; `claude mcp list` reported it connected. With the placeholder left in place of the key it reported the `401` and `invalid_api_key`. A headless session given the sentence the page suggests called `get_me`, `list_contests`, `get_contest` and `list_my_entries` and stopped to ask before entering. |
| `curl` | `initialize`, `tools/call`, the `401` and the `405` |
| claude.ai, Claude Desktop, Claude mobile | **Not tested.** They need a public HTTPS address, and either OAuth or the request-headers beta. |

Not exercised against a live server by any client: `submit_entry` and
`edit_entry` succeeding. A local stack has no Solana program to pay, so those
are covered by the test suite, against the same vault double the REST tests use.

### What OAuth would need

Not built. Written down so the next piece starts from the seams and not from a
search. claude.ai's requirements are in Anthropic's [Authentication for
connectors](https://claude.com/docs/connectors/building/authentication).

| Piece | Where it plugs in |
|-------|-------------------|
| Recognising an access token | `authenticate_api_key!` in `ApiKeyAuthentication` is the one step that turns a bearer value into a player. A second scheme branches there, on the token's prefix (`tmk_` is a key). Everything after it asks only for `current_user`, `current_api_key` and `write_refusal`. |
| What an access token must carry | What a key carries: the player, an expiry, a way to revoke, and the **eligibility stamp** (location, and age when the gate is on) taken in the player's browser. A key gets it at creation; an OAuth grant would take it on the consent screen, which is a page on this site. |
| `GET /api/v1/me` and `get_me` | They report `api_key.prefix`, `name`, `expires_at`, `eligibility`. An OAuth caller has no key, so that block needs a second shape. |
| The `401` | Claude starts sign-in from a `401` whose header points at metadata: `WWW-Authenticate: Bearer resource_metadata="https://turfmonster.media/.well-known/oauth-protected-resource"`. Today's header names only a realm. |
| Discovery | `/.well-known/oauth-protected-resource` (RFC 9728; `resource` must equal the `/mcp` URL exactly) and authorization server metadata (RFC 8414). |
| The authorization server | Authorization code with PKCE `S256`; a client identity for Claude (a Client ID Metadata Document, or Dynamic Client Registration); the redirect URI `https://claude.ai/api/mcp/auth_callback`, and a loopback redirect on any port for Claude Code; a token endpoint that takes form-encoded bodies and rotates refresh tokens. |
| Rate limits | `mcp/key` is keyed on a digest of whatever bearer value is sent, so nothing there. The per-address limit lifts for a credential once it has authenticated (`Rack::Attack.mcp_mark_verified`, called from the controller), which an access token would get the same way. |
| The `Origin` check | `McpController#refuse_foreign_origin` answers `403` to every `Origin` but this site's own, `https://claude.ai` included. Claude's connector calls from Anthropic's servers and sends no `Origin`, so this does not block it; but an OAuth consent or callback page, or any browser-side client, that posts to `/mcp` from another origin will be refused until that origin is allowed there. |
| The tools | Nothing. |

### For developers: the MCP endpoint

| Piece | Where |
|-------|-------|
| Route (drawn from its own file) | `config/routes/mcp.rb` |
| HTTP: the Origin check, the key, the body, the write gates | `app/controllers/mcp_controller.rb` |
| The protocol: JSON-RPC, revisions, `tools/list`, `tools/call` | `app/services/agent_mcp/server.rb`, `protocol.rb` |
| The eight tools: names, descriptions, schemas, the operation each runs | `app/services/agent_mcp/tools.rb`, `tool.rb` |
| An operation's outcome as a tool result | `app/services/agent_mcp/tool_result.rb` |
| The `instructions` text | `app/services/agent_mcp/instructions.rb` |
| The work, shared with `/api/v1` | `app/services/api/v1/operations/` |
| Throttles | `config/initializers/rack_attack.rb` (`mcp/key`, `mcp/unverified_ip`) |
| Which header names the client address | `config/initializers/forwarded_headers.rb` |

A tool holds no rule of the game. To add one, write the operation, call it from
a REST action, and add a `Tool` to the registry that names it. A tool that
writes is declared `writes: true`, which is what puts it behind the account
hold and the age gate.

## For developers

| Piece | Where |
|-------|-------|
| Key model | `app/models/api_key.rb` |
| Bearer authentication, the error envelope, the freeze gate, the age re-check | `app/controllers/concerns/api_key_authentication.rb` |
| API base controller | `app/controllers/api/v1/base_controller.rb` |
| Create and revoke | `app/controllers/api_keys_controller.rb` |
| The eligibility gates, one answer for the card and the server | `ApplicationController#api_key_mint_blocker` |
| Account card (a Turbo Frame; every `ApiKeysController` response carries it, so create, revoke and passing the age gate update the card in place) | `app/views/accounts/_api_keys_section.html.erb` |
| Throttles | `config/initializers/rack_attack.rb` (`api/key`, `api/ip`, `api_key_mint/ip`) |

To add an endpoint, subclass `Api::V1::BaseController` and add the route to
`config/routes/api_v1.rb` (drawn inside the `namespace :api` block in
`config/routes.rb`). Authentication, the error envelope and the throttle apply
without further wiring. A surface that cannot
inherit from the base controller includes `ApiKeyAuthentication` directly and
gets the same.

### Write gates

| Gate | Default | How an endpoint uses it |
|------|---------|-------------------------|
| Account hold | **On for every non-`GET`/`HEAD` request.** Nothing to add. | Opt an action out with `allow_frozen_account_writes only: :action`. That action then owes the check itself. `only:` is required: called without it, or with an empty list, the method raises, because that spelling would lift the hold from every action of the controller. |
| Age gate | Off. An endpoint asks for it. | `before_action :require_age_verified` on any action that enters a contest. |
| Location | Never re-checked. | Decided at key creation (Alex, 2026-09-30). |

A write endpoint with one action per operation needs one line:

```ruby
class Api::V1::EntriesController < Api::V1::BaseController
  before_action :require_age_verified, only: %i[create update]
  # The account hold already covers create and update: they are not GETs.
end
```

Each gate is also a plain question that renders nothing and returns `nil` or a
`Refusal` (`code`, `message`, `status`): `frozen_account_refusal`,
`age_gate_refusal`, and `write_refusal` for both, hold first. That form is for a
surface where one action carries many operations and answers in its own
envelope, such as an MCP endpoint dispatching tools through one `POST`:

```ruby
class McpController < ActionController::API
  include ApiKeyAuthentication
  allow_frozen_account_writes only: :rpc   # read tools must stay open

  def run_tool(tool, arguments)
    refusal = write_refusal
    return Api::V1::Operations::Outcome.refused(refusal) if tool.writes? && refusal
    # ...
  end
end
```

An action that opts out and then forgets to ask is open to a frozen account, so
keep the opt-out to the one dispatching action.

The API base controller is `ActionController::API`, not `ApplicationController`,
on purpose: the browser stack's `allow_browser` guard, CSRF check, session-token
check, IP geo detection and profile-completion redirect do not apply to a bearer
client, and a filter added there later cannot start applying here by accident.

## The agent pages

Four public URLs tell people and agents how to use this API. None needs a
session, and none is behind the `allow_browser` guard, because an LLM's fetch
tool and `curl` are who reads them.

| URL | Reader | What it is |
|-----|--------|------------|
| `/agents` | A person | A starter prompt to copy, three steps to a key, the command that connects Claude Code to `/mcp`, which assistants work today, a short endpoint table |
| `/agents/guide` | An agent, or a developer | The agent guide as a page: rules, scoring, locks, prizes, eligibility, every endpoint and error, retries, the MCP endpoint and its tools, and how to reason about a lineup |
| `/agents/guide.md` | An agent | The same guide as plain Markdown, served `text/markdown` |
| `/llms.txt` | An agent | A pointer to the Markdown guide |

**This file is the contract; the guide is its public reading.** When an endpoint,
a field or an error code changes here, change `guide_source.text.erb` in the
same PR. `test/integration/agent_guide_guard_test.rb` fails if the guide names a
route the app does not draw or an error code its source does not emit, and
fails the other way round too: a new API route or refusal code with no row in
the guide. It holds the MCP tools the same way: a tool name written on any page
must be in `AgentMcp::Tools::ALL`, every registry tool must have a row in the
guide with its schema's arguments, and the REST request the guide pairs a tool
with must be the one whose action runs that tool's operation.

**One source for the guide.** `app/views/agents/guide_source.text.erb` is
Markdown with ERB. `/agents/guide.md` serves the rendered string as it is, and
`/agents/guide` passes the same string through `MiniMarkdown`
(`app/services/mini_markdown.rb`), a renderer for the subset the guide is
written in: headings, paragraphs, one-level lists, fenced code, tables, inline
code, bold and links. The app has no Markdown gem, and the renderer raises on
anything outside that subset, so a construct it cannot render fails a test
instead of reaching the page as literal text. A link to a section of the same
page is rendered `data-turbo="false"`: followed by Turbo, the jump ignored the
heading's scroll margin and landed it under the navbar.

**Numbers come from the code.** The guide reads the multiplier curve
(`SlateMatchup.turf_score_for`), the bye factor, the worked example
(`TurfMonsterRules`), prize splits (`Contest::FORMATS`), the key lifetime
(`ApiKey::LIFETIME`), the rate limits (`Rack::Attack.throttles`), ages by state
(`AgePolicy`) and the excluded states (`Studio::GeoSetting`). Its MCP section
reads the tools and their arguments from `AgentMcp::Tools::ALL`, the revisions
and JSON-RPC codes from `AgentMcp::Protocol`, and the limits from
`Rack::Attack`. Do not type one in. The one thing typed there is the REST
request each tool stands for, which the guard test holds to the code.

**The starter prompt** is `app/views/agents/_starter_prompt.text.erb`, rendered
once per request and handed to both the block a person reads and the copy
button. It names production's canonical host (`TurfMonster::HostConfig::DEFAULT_APP_HOST`)
on every environment, so a prompt copied from a desk never sends an agent to
localhost.

**The Claude Code command** is built once, by `AgentsController#mcp_connect_command`,
from the production host, the `/mcp` route and the server's own name, and used
three times: the block on `/agents`, its copy button, and the guide. It is one
line, with `--header` last (the option takes a list, so placed before the name
it swallows the name: `error: missing required argument 'name'`). The key's
place is held by `PASTE_YOUR_API_KEY_HERE`.

**What the pages say about clients.** Claude Code works today with a key. The
Claude chat app (claude.ai, desktop, mobile) does not for most accounts: a
custom connector there cannot carry a personal key, because Anthropic documents
request headers as a beta for a limited set of organizations. The pages say
that in the present tense and send chat users to Claude Code.

**What the pages do not say.** They do not say or imply that the chat app will
be able to connect later: nothing that would make it so (see [What OAuth would
need](#what-oauth-would-need)) has a go-ahead. They name the MCP endpoint only
on the production host, render no key-shaped string, promise no grading or
payout timing, and do not say a payment cannot repeat.
`test/controllers/agents_controller_test.rb` holds each of those.

**What the pages say about the Terms.** Until 2026-10-01 the pages said nothing
about what the Terms allow an agent to do, because the Terms forbade "automated
agents". The Terms' "Acceptable use" section (`app/views/pages/terms.html.erb`,
the list item with id `ai-agents`) now carries wording Alex approved on
2026-10-01, and it is binding copy: change it only on his word.

> You may use an AI agent or other software to play through our official API,
> on your own account and with your own API key. You remain responsible for
> everything it does. Do not use automation to run more than one account, to
> coordinate entries with other players, or to reach the game by any route
> other than the official API.

The pages restate that rule and link the Terms at `#ai-agents`: `/agents` in the
paragraph under "What your key can and cannot do", the guide under "Before you
start" in the section "What the Terms permit". Both name the same things
and no others: the official API, the player's own account, the player's own
key, the player's responsibility, and the three prohibitions (more than one
account, coordinating entries with other players, any route other than the
official API). The guide also says the official API is both the REST API and
the MCP endpoint, so a tool-calling agent is not left to guess. The pages must
not say more or less than the Terms do.
`test/integration/agent_terms_consistency_test.rb` holds the Terms to the
approved wording verbatim and each page to the Terms.

| Piece | Where |
|-------|-------|
| Routes | `config/routes.rb`, below every line `docs/workflows` cites |
| Controller | `app/controllers/agents_controller.rb` |
| The human page | `app/views/agents/show.html.erb` |
| The guide's one source | `app/views/agents/guide_source.text.erb` |
| The Markdown subset renderer | `app/services/mini_markdown.rb` |
| Browser checks at phone width | `e2e/agents_pages.spec.js` |
