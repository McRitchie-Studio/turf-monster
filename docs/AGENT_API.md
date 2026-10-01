# Agent API

A JSON API that lets an AI agent act for one Turf Monster player without a
browser. This page is the contract for what is shipped. It supersedes the
authentication design in [`BOT_API.md`](BOT_API.md).

**Shipped so far:** API keys, bearer authentication, `GET /api/v1/me`, the
rate-limit tier, and the read endpoints for contests, leaderboards and the
player's entries. Entry writes, the `/agents` pages and an MCP endpoint are later
pieces of the same epic and build on what is here.

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
  No shipped endpoint asks yet; the entry endpoints will.

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
| 400 | `bad_request` | A required parameter is missing |
| 404 | `not_found` | No such resource |
| 429 | `rate_limited` | Too many requests. The body also carries `retry_after` (seconds), and so does the `Retry-After` header. |
| 500 | `internal_error` | Our fault. Retry shortly. |

A 401 also carries `WWW-Authenticate: Bearer realm="Turf Monster API"`.

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
  one is.

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
| `accepting_entries` | The one-field answer to "could a new entry go in now": open, not locked, not cancelled, not coming soon, a spot left, and the player under their own limit. It says nothing about the player's wallet or account. |
| `locks_at` | When the contest locks. Every pick in every entry is final from this moment, including picks whose own game starts later. `null` means no lock is scheduled. |
| `concludes_at` | When results are scheduled to be final, if set |
| `guaranteed_prize_cents` | The sum of `payouts` |
| `payouts` | Prize per finishing rank. Ranks not listed win nothing. Tied entries pool the prizes of the places they cover and split them: two entries tied for first share first and second prize. |
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
      "turf_score": 2.7,
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
      "score": 215.9,
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
      "score": 215.9,
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
      "score": 215.9,
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
          "turf_score": 2.7,
          "expected_team_score": 21.5,
          "team_score": 17,
          "locked": true,
          "games_count": 1,
          "bye_weeks": [5],
          "games": [ { "week": 4, "...": "as above" } ],
          "points": 45.9
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
| `editable` | `true` while the entry's picks can still be replaced: the entry is active and its contest is open and not locked. Even then, a pick whose own `locked` is `true` cannot be swapped out, and a locked team cannot be swapped in. |
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
| 400 | `bad_request` | `status` is not `open` or `settled` |
| 401 | the four key errors above | No key, or a bad, revoked or expired one |
| 404 | `not_found` | Unknown contest or entry slug; a `pending` contest; another player's entry; a cart or abandoned entry |
| 429 | `rate_limited` | The limits above apply to every route here |

```json
{ "error": { "code": "bad_request", "message": "status must be one of: open, settled." } }
```

### For developers: the read endpoints

| Piece | Where |
|-------|-------|
| Routes (drawn from their own file so `config/routes.rb` line numbers hold) | `config/routes/api_v1.rb` |
| Contests, contest detail, leaderboard | `app/controllers/api/v1/contests_controller.rb` |
| The player's entries | `app/controllers/api/v1/entries_controller.rb` |
| Paging | `app/controllers/api/v1/pagination.rb` |
| Contest JSON | `app/serializers/api/v1/contest_serializer.rb` |
| Entry and leaderboard-row JSON | `app/serializers/api/v1/entry_serializer.rb` |
| Team rows and picks, from one load of the slate | `app/serializers/api/v1/board.rb` |
| Slate facts for a page of contests in two queries (mirrors `Contest`; the test holds the two together) | `app/serializers/api/v1/contest_facts.rb` |
| Tie-aware rank before a contest settles (the rule `Contest#grade!` applies) | `app/serializers/api/v1/ranking.rb` |
| The web's visibility and capacity rules, reused as written | `app/serializers/api/v1/web_rules.rb` wrapping `ContestsHelper` |

The serializers are plain objects that return hashes, so another surface (the
MCP endpoint) can return the same shapes without going through a controller.

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
| Account hold | **On for every non-`GET`/`HEAD` request.** Nothing to add. | Opt an action out with `allow_frozen_account_writes only: :action`. That action then owes the check itself. |
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
  allow_frozen_account_writes only: :call_tool   # read tools must stay open

  def call_tool
    if tool.writes? && (refusal = write_refusal)
      return render json: tool_error(refusal.code, refusal.message)
    end
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
