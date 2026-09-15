# Bot API — Planned (design only)

REST API for headless bot agents to interact with Turf Monster programmatically. Bots would join contests, make selections, and submit entries without a browser.

> **Status (2026-05-23): DESIGN ONLY — NOT IMPLEMENTED. No `/api/v1/*` routes exist in `config/routes.rb` and no controllers under `app/controllers/api/v1/`. This doc describes a future surface.**
>
> **For bot integration today**, use the existing browser-shaped flow: `/auth/solana/nonce` + `/auth/solana/verify` (the same Solana auth used by Phantom), then standard Rails contest endpoints (`POST /contests/:id/toggle_selection`, `POST /contests/:id/enter`, etc.) with the resulting session cookie. The Ed25519 signature is verified via `Solana::AuthVerifier` (in the `solana-studio` gem) with the canonical host-bound message prefix (OPSEC-018).
>
> Building this API at a `/api/v1/*` namespace requires: a controller hierarchy under `app/controllers/api/v1/`, token-based session auth (replacing or complementing the Rails cookie), JSON-only renderers, and rate-limiting via `rack-attack`. Revisit when there's a real bot integration demand — until then, prefer the browser-shaped flow + a thin wrapper client.

---

## Auth: Solana Signature + Session Token

Bots authenticate the same way as browser users — by signing a message with their Solana keypair.

### Flow

1. Bot generates or loads an Ed25519 keypair locally
2. `POST /api/v1/auth` — bot sends a signed SIWS (Sign In With Solana) message
3. Server verifies the Ed25519 signature using existing `Solana::AuthVerifier`
4. Server returns a session token (opaque, 24h TTL)
5. All subsequent requests include `Authorization: Bearer <token>`

### Auth Request

```
POST /api/v1/auth
Content-Type: application/json

{
  "message": "<domain> wants you to sign in with your Solana account:\n<pubkey>\n\nSign in to Turf Monster\n\nNonce: <nonce>",
  "signature": "<base58-encoded signature>",
  "pubkey": "<base58-encoded public key>"
}
```

### Auth Response

```json
{
  "success": true,
  "token": "tm_bot_a1b2c3d4e5f6...",
  "expires_at": "2026-04-13T00:00:00Z",
  "user": {
    "slug": "mcritchie",
    "username": "mcritchie",
    "wallet": "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd"
  }
}
```

### Getting a Nonce

```
GET /api/v1/auth/nonce

→ { "nonce": "abc123..." }
```

Reuses existing `/auth/solana/nonce` logic.

---

## Endpoints

All endpoints require `Authorization: Bearer <token>` except auth and nonce.

### Contests

```
GET /api/v1/contests
```

List open contests. Returns summary array.

```json
{
  "contests": [
    {
      "slug": "world-cup-2026-md1",
      "name": "World Cup 2026 — Matchday 1",
      "status": "open",
      "entry_fee_cents": 900,
      "max_entries": 100,
      "current_entries": 42,
      "starts_at": "2026-06-11T16:00:00Z",
      "picks_required": 6
    }
  ]
}
```

---

```
GET /api/v1/contests/:slug
```

Contest details with available matchups.

```json
{
  "contest": {
    "slug": "world-cup-2026-md1",
    "name": "World Cup 2026 — Matchday 1",
    "status": "open",
    "entry_fee_cents": 900,
    "onchain": true,
    "contest_pda": "...",
    "matchups": [
      {
        "id": 123,
        "team": "Argentina",
        "team_slug": "argentina",
        "opponent": "Saudi Arabia",
        "multiplier": "1.5",
        "locked": false
      }
    ]
  }
}
```

### Selections

```
POST /api/v1/contests/:slug/selections
```

Toggle a selection (same as the browser flow).

```json
{ "matchup_id": 123 }
```

Response:

```json
{
  "success": true,
  "selections": [123, 456, 789],
  "count": 3
}
```

### Entry

```
POST /api/v1/contests/:slug/entry
```

Confirm entry. For onchain contests, the bot must include a pre-signed transaction.

**Offchain contest:**
```json
{}
```

**Onchain contest:**
```json
{
  "message": "<identity message>",
  "signature": "<base58 signature>",
  "pubkey": "<base58 pubkey>"
}
```

Server responds with `prepare_entry` data. Bot signs the transaction locally, then:

```
POST /api/v1/contests/:slug/confirm_entry
```

```json
{
  "tx_signature": "<solana tx signature>",
  "entry_id": 42,
  "entry_pda": "..."
}
```

Response:

```json
{
  "success": true,
  "entry_slug": "entry-42",
  "tx_signature": "5abc...",
  "seeds_earned": 60,
  "seeds_total": 180
}
```

### Account

```
GET /api/v1/account
```

```json
{
  "slug": "mcritchie",
  "username": "mcritchie",
  "wallet": "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd",
  "usdc_balance": 500.00,
  "seeds_total": 180,
  "level": 2
}
```

---

## Implementation Notes

### Controller Structure

```
Api::V1::BaseController          — token auth, JSON responses, rescue_from
Api::V1::AuthController          — nonce, create (sign-in)
Api::V1::ContestsController      — index, show
Api::V1::SelectionsController    — create (toggle)
Api::V1::EntriesController       — create, confirm
Api::V1::AccountsController      — show
```

### Token Storage

- `BotToken` model: `token`, `user_id`, `expires_at`, `last_used_at`
- Token format: `tm_bot_<SecureRandom.hex(32)>`
- Lookup: `BotToken.find_by(token: header_token)&.user` with expiry check

### Reuse Existing Logic

- `Solana::AuthVerifier` — signature verification
- `Contest#prepare_entry_for` — transaction building
- `Entry#confirm!` / `Entry#confirm_onchain!` — entry confirmation after payment proof
- `rescue_and_log` — error logging pattern

---

## Future Considerations

- **Rate limiting**: Per wallet address, configurable per endpoint
- **Bot registration**: Admin registers bot wallets, assigns roles
- **Webhooks**: Notify bots of contest state changes (open → settled; plus the derived lock/conclusion time-gates)
- **Batch selections**: Submit all 6 selections at once instead of toggling individually
- **Leaderboard API**: `GET /api/v1/contests/:slug/leaderboard`
- **WebSocket**: Real-time contest updates for active bots

---

## Security

- Tokens are opaque — no JWT (simpler, revocable)
- Rate limit: 60 requests/minute per token
- Token revocation: `DELETE /api/v1/auth` invalidates the current token
- Admin can revoke all tokens for a wallet via admin panel
- Bot wallets are regular user accounts — same balance, same entry rules
