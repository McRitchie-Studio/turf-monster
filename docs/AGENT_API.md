# Agent API

A JSON API that lets an AI agent act for one Turf Monster player without a
browser. This page is the contract for what is shipped. It supersedes the
authentication design in [`BOT_API.md`](BOT_API.md).

**Shipped so far:** API keys, bearer authentication, `GET /api/v1/me`, and the
rate-limit tier. Contest reads, entry writes, the `/agents` pages and an MCP
endpoint are later pieces of the same epic and build on what is here.

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
| 403 | `account_frozen` | The account is on hold; actions that spend are refused. Reads still work. |
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
| `api_key.name` | The label the player gave the key, or `null` |
| `api_key.eligibility.age_gate` | `passed`, or `not_required` when the age gate was off at creation |

This endpoint is read-only, so it answers for a frozen account.

## For developers

| Piece | Where |
|-------|-------|
| Key model | `app/models/api_key.rb` |
| Bearer authentication, the error envelope, the freeze gate | `app/controllers/concerns/api_key_authentication.rb` |
| API base controller | `app/controllers/api/v1/base_controller.rb` |
| Create and revoke | `app/controllers/api_keys_controller.rb` |
| The eligibility gates, one answer for the card and the server | `ApplicationController#api_key_mint_blocker` |
| Account card (a Turbo Frame; every `ApiKeysController` response carries it, so create, revoke and passing the age gate update the card in place) | `app/views/accounts/_api_keys_section.html.erb` |
| Throttles | `config/initializers/rack_attack.rb` (`api/key`, `api/ip`, `api_key_mint/ip`) |

To add an endpoint, subclass `Api::V1::BaseController` and add the route inside
the `namespace :api` block in `config/routes.rb`. Authentication, the error
envelope and the throttle apply without further wiring. Put
`before_action :require_unfrozen_account` on any action that spends money or a
free entry. A surface that cannot inherit from the base controller includes
`ApiKeyAuthentication` directly.

The API base controller is `ActionController::API`, not `ApplicationController`,
on purpose: the browser stack's `allow_browser` guard, CSRF check, session-token
check, IP geo detection and profile-completion redirect do not apply to a bearer
client, and a filter added there later cannot start applying here by accident.
