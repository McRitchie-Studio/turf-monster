# Coinbase CDP Onramp + Offramp (USDC on Solana) — turf-monster implementation spec

> Generated 2026-06-09 from a doc-extraction pass over live docs.cdp.coinbase.com pages (81 facts, every claim source-cited below). The Ruby JWT recipe in §3 was verified locally against this repo's exact gem versions. Where two doc pages conflict, the conflict is recorded in **Open questions** and the spec states the default we build to.
>
> Provider selection rationale (why Coinbase over MoonPay/Transak/Ramp/Stripe) lives in the 2026-06-09 ramp research: MoonPay's and Ramp's terms prohibit our category; Stripe has no consumer off-ramp and prohibits paid-entry prize contests outright. Coinbase + Transak were the only capability-complete options without a verified categorical prohibition.

**Scope.** Hosted-page integration on `turfmonster.media` (Rails 7 / Heroku), with `app.turfmonster.media` kept as a legacy alias while provider dashboards migrate. Buy = onramp USDC into the user's Solana wallet; Sell = offramp USDC to fiat via the Coinbase-hosted widget. Both wallet modes: Phantom (`user.web3_solana_address`, self-custody) and managed (`user.web2_solana_address`, server can sign). Primary integration is the **v1 session-token flow** (`POST /onramp/v1/token`) because it is the only documented path for offramp and serves both directions [^1][^4]; the v2 `POST /v2/onramp/sessions` API is noted as an optional later swap for buy-side only [^17]. Session tokens are mandatory for all hosted URLs since 2025-07-31 [^18].

## 1. Gems

- Already bundled: `jwt (3.1.2)`, `ed25519 (1.4.0)` (`Gemfile.lock`).
- **Add `gem "jwt-eddsa", "~> 0.9"`** and `require "jwt/eddsa"` in the auth service. Vanilla jwt 3.x raises `JWT::EncodeError: Unsupported signing method` for EdDSA — the CDP docs' Ruby snippet predates jwt 3.0's extraction of EdDSA into jwt-eddsa and does NOT work as written against this bundle (verified locally on the exact gem versions) [^2].
- Housekeeping: jwt-eddsa 0.9.0 was `--user-install`ed to `~/.gem/ruby/3.1.0` during verification; the Gemfile entry supersedes it.
- Zero-new-gem fallback: create the CDP Secret key as **ECDSA** and sign `ES256` via `OpenSSL::PKey::EC.new(pem)` — verified working on jwt 3.1.2 with no extra gems — at the cost of the "legacy" key type [^2].

## 2. Env vars + feature flag

| Var | Purpose |
|---|---|
| `CDP_API_KEY_ID` | Secret API Key UUID — used as both JWT `kid` header and `sub` claim |
| `CDP_API_KEY_SECRET` | base64; MUST decode to exactly 64 bytes (32-byte Ed25519 seed ‖ 32-byte pubkey); validate and raise on mismatch [^3] |
| `CDP_WEBHOOK_SECRET` | Phase 2 only — `metadata.secret` returned once at webhook subscription creation [^12] |
| `ENABLE_CDP_RAMP` | Feature flag, off by default everywhere |

Feature flag follows the existing `AppFlags.test_scaffolding?` pattern in `app/services/app_flags.rb`:

```ruby
def self.cdp_ramp?
  ENV["ENABLE_CDP_RAMP"].to_s.strip.downcase == "true"
end
```
Gate routes, controllers, and all UI entry points on it (kill-switch = unset the var).

**A UI entry point asks `cdp_ramp_modal_available?`, not `AppFlags.cdp_ramp?`**
(`app/helpers/onramp_helper.rb`). Every `cdp-ramp` opener is a handoff to a MODAL,
and the host layout registers that modal behind `logged_in?` AND the flag. An
opener that asks a WIDER question than the registration ships a button that swaps
to an unregistered modal id: the host finds no template, the card opens empty, and
nothing raises. Two ways that happened, both fixed 2026-09-07:

- `onramp_rail_visible?` reveals every rail outside production for design review,
  so the Coinbase rail rendered in dev and in the whole test suite with the flag
  off. Coinbase now short-circuits to `cdp_ramp_modal_available?` in every env,
  because it is the one rail whose destination is a modal rather than a route.
- `wallet-topup` and `onramp-hub` are registered UNGATED (they must survive an
  in-session signup, where the server-rendered `logged_in?` was still false) while
  `cdp-ramp` is registered under `logged_in?`. On that page the rail outlived its
  destination even with the flag ON.

`app/views/cdp/returns/show.html.erb` needs no view guard: `Cdp::BaseController`
prepends `head :not_found unless AppFlags.cdp_ramp?`, so the page cannot render
with the flag off (regression: `test/controllers/cdp/returns_controller_test.rb`).

Kill-switch behaviour is pinned by `test/views/cdp_ramp_kill_switch_test.rb`.

## 3. `Cdp::Auth` — per-request JWT (`app/services/cdp/auth.rb`)

Exact recipe (Ed25519 / EdDSA) [^2][^3]:

```ruby
decoded = Base64.decode64(ENV.fetch("CDP_API_KEY_SECRET"))
raise "Invalid Ed25519 key length" if decoded.length != 64
signing_key = Ed25519::SigningKey.new(decoded[0, 32])
header = { alg: "EdDSA", typ: "JWT", kid: key_id, nonce: SecureRandom.hex(16) }
claims = {
  sub: key_id, iss: "cdp", aud: ["cdp_service"],
  nbf: Time.now.to_i, exp: Time.now.to_i + 120,            # 2-minute max validity
  uri: "#{method.upcase} api.developer.coinbase.com#{path}" # e.g. "POST api.developer.coinbase.com/onramp/v1/token"
}
JWT.encode(claims, signing_key, "EdDSA", header)
```

- `uri` claim = `METHOD<space>host<path>` — no scheme, no space between host and path; it binds the JWT to ONE method+host+path [^2].
- The signed path **EXCLUDES the query string** — every official CDP example builds the claim from the path only and the official SDKs sign `url.pathname` (the Coinbase REST auth docs say explicitly not to include query parameters in the signed path). Sign `path.split("?").first`; the query stays on the actual request URI. The failure mode of signing the query is asymmetric and nasty: `POST /onramp/v1/token` (no query) works and money moves, while every status poll and catalog GET 401s — status tracking dead, offramp `to_address` discovery dead, and the fail-closed catalog masquerades as a geo problem.
- Generate a **fresh JWT per request**; never cache (120 s expiry + per-URI binding).
- Sent as `Authorization: Bearer <jwt>` on every CDP REST call [^3].

## 4. `Cdp::Client` (`app/services/cdp/client.rb`)

Thin HTTP wrapper for `https://api.developer.coinbase.com`: `get(path, params)` / `post(path, body)` → fresh `Cdp::Auth` JWT, JSON body, typed error wrapping the Status schema `{code, message, details}` [^1]. Casing is mixed by design — request bodies camelCase (`addresses`, `clientIp`), v1 responses snake_case (`partner_user_ref`, `to_address`), webhook payloads camelCase — translate at call sites, no global key transform. Money pairs are `{value: String, currency: String}` — parse `value` with `BigDecimal`, never Float. Route through the existing `OutboundRequestLogger` for parity with the rest of the outbound stack.

## 5. `Cdp::SessionTokenService` — the shared token mint

`POST https://api.developer.coinbase.com/onramp/v1/token` [^1] — same endpoint for buy AND sell [^4].

```json
{
  "addresses": [{ "address": "<user solana pubkey>", "blockchains": ["solana"] }],
  "assets": ["USDC"],
  "clientIp": "<request.remote_ip>"
}
```

- Onramp: address = **destination** wallet. Offramp: address = **source** of funds being sold [^4]. One address per network.
- Address selection — **both directions ask the SESSION** (`SessionContext#web3?`), never account identity: `web3_solana_address` when this session authenticated with Phantom, else the managed `web2_solana_address`. Onramp credits the wallet the session can spend from; offramp sources the wallet it can sign with. One exception, onramp only: an account with no managed wallet gets `web3_solana_address` as the destination rather than a refusal. `User#solana_address` is deliberately NOT used — it is web3-preferred, so it credited Phantom for a combo account whose entry pays from the managed wallet.
- Exact values for USDC-on-Solana: asset ticker `"USDC"`, network slug `"solana"` (lowercase); "To enable USDC on the Solana network, you must pass in a Solana formatted destination address" [^19].
- `clientIp`: treat as **required** (the canonical `/onramp/reference` page marks it required; see open questions for the page conflict). Heroku tension: docs say "Do not trust X-Forwarded-For", but Heroku's router delivers the client IP only via XFF and appends the true client last — `request.remote_ip` is the only realistic source; document the assumption [^1].
- Response: `{"token": "...", "channel_id": ""}`. Token is **single-use and expires after 5 minutes** — mint at click time (AJAX), never at page render, never cache [^1][^5].
- Do NOT use the deprecated `destinationWallets` param [^1].

## 6. Onramp URL builder (`Cdp::OnrampUrl`)

Base: `https://pay.coinbase.com/buy/select-asset` [^4][^6]. Params (documented set only):

| Param | Value |
|---|---|
| `sessionToken` | required, from §5 |
| `partnerUserRef` | `tm-#{user.id}-#{ramp.id}` (per-session; must be < 50 chars; note it is `partnerUserRef`, NOT `partnerUserId`) [^6] |
| `redirectUrl` | `https://turfmonster.media/cdp/onramp/return` — production values must be on the domain allowlist [^7] |
| `defaultNetwork` | `solana` [^19] |
| `defaultAsset` | `USDC` (ticker-vs-UUID format unverified — open questions) |
| optional | `presetFiatAmount` (USD/CAD/GBP/EUR only; ignored if `presetCryptoAmount` set), `presetCryptoAmount`, `defaultExperience` (`buy`\|`send`), `defaultPaymentMethod`, `fiatCurrency`, `handlingRequestedUrls` [^6] |

## 7. Offramp URL builder (`Cdp::OfframpUrl`)

Base: `https://pay.coinbase.com/v3/sell/input` [^8]. **`sessionToken`, `partnerUserRef` (<50 chars), and `redirectUrl` are ALL required for offramp** [^8]. Optional: `defaultNetwork=solana`, `defaultAsset=USDC`, `presetCryptoAmount` XOR `presetFiatAmount`, `defaultCashoutMethod` (`FIAT_WALLET`|`CRYPTO_ACCOUNT`|`ACH_BANK_ACCOUNT`|`PAYPAL`), `fiatCurrency`, `disableEdit` [^8]. `redirectUrl` → `https://turfmonster.media/cdp/offramp/return`.

Alternative (later): `POST /onramp/v1/sell/quote` with `sourceAddress`, `redirectUrl`, `partnerUserId` returns a ready `offramp_url` + `quote_id` for one-click sell — note the **quote API uses `partnerUserId` while the URL/status APIs use `partnerUserRef`** [^9].

## 8. Routes + controllers

```ruby
scope :cdp do
  post "onramp_sessions",  to: "cdp/ramp_sessions#create_onramp"
  post "offramp_sessions", to: "cdp/ramp_sessions#create_offramp"
  get  "onramp/return",    to: "cdp/returns#onramp"
  get  "offramp/return",   to: "cdp/returns#offramp"
end
post "webhooks/cdp", to: "webhooks/cdp#create"  # phase 2
```

`Cdp::RampSessionsController`: `Cdp::BaseController` skips the normal HTML login redirect and enforces API auth directly across the CDP surface, so unauthenticated requests return `401` JSON for every requested format and can never redirect into a final `200` app page. `AppFlags.cdp_ramp?` still 404s the entire CDP surface when the flag is off. Geo gate (§13), then session-token POSTs create a `CdpRampTransaction` row → mint session token → build URL → `render json: { url: }`. Security requirements [^7]: strict explicit CORS only — production allowlist derives from `APP_HOST` plus `APP_HOST_ALIASES`, non-production also allows `http://localhost:3100`, optional override via `CDP_ALLOWED_ORIGINS`; never wildcard. User auth is mandatory before minting — "you will be liable for any misuse of your endpoints". Reuse the existing Phase-1 general/ip rate-limit throttle on both endpoints.

`Cdp::ReturnsController`: marks `returned_at`, enqueues the relevant poll job, renders the status page. **The redirect carries NO documented query params — treat it as a UX-only signal, never as confirmation** [^6][^8].

## 9. Persistence — `CdpRampTransaction`

`user_id`, `direction` (enum onramp/offramp), `partner_user_ref` (unique index), `wallet_address`, `wallet_mode`, `status` (local lifecycle: `initiated → token_minted → returned → cdp_created → sending → sent → success | failed | expired | abandoned`, plus raw CDP status), `coinbase_transaction_id` (idempotency key for upserts), `tx_hash`, `to_address`, `sell_amount_value:decimal` / `sell_amount_currency`, `asset`, `network`, `payment_method`, `raw_payload:jsonb`, `cashout_deadline_at`, `sent_signature`, `broadcast_at`, `failed_send_count` (failed landings counted toward the cap in §10), timestamps.

## 10. Offramp post-commit send — BOTH wallet modes

After the user clicks "Cash out now" in the widget, CDP creates a transaction whose `to_address` is "a Coinbase managed onchain address where funds are sent to be offramped" — **"Your app must facilitate this onchain transaction"** within the **30-minute window** [^10]. There is no redirect param carrying `to_address`; it comes only from the Offramp Transaction Status API [^10].

**Discovery (both modes):** `Cdp::OfframpPollJob` (§11) polls until a row with `status: TRANSACTION_STATUS_CREATED` appears; persist `to_address`, `sell_amount`, `network`, set `cashout_deadline_at = created_at + 30.minutes`.

**Managed mode (server signs):** new `Cdp::OfframpSendJob`:
- Build the USDC SPL transfer from the user's web2 ATA to `to_address`, mirroring `Solana::Vault#transfer_spl` but with **authority = the user's managed keypair** (`Solana::Keypair.from_encrypted`), mint = `Solana::Config::USDC_MINT` (mainnet `EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v`), amount = `BigDecimal(sell_amount.value) * 10**6` base units.
- `to_address` ambiguity: docs never say whether the Solana `to_address` is an owner address or a token account — inspect on-chain (owned by SPL Token program → use directly as token account; else derive its USDC ATA). Confirm on first mainnet sell (open questions).
- Guards: **fresh explicit user confirmation click in our UI before the server moves funds**; balance check; refuse sends past `cashout_deadline_at` minus a ~3-minute safety margin; record `sent_signature`; **verify signature status before any retry** (never blind-resend — same class of bug as the Lazarus `recover_pending_entry` finding).

**Phantom mode (client signs, the HOUSE pays):** the offramp return page (plus a StateFanout-driven prompt) shows "Send X USDC to Coinbase" with a live countdown. The **server** builds the SPL transfer — it is the single source of truth for both the destination and the amount, and the client never dictates either. Copy must state the late-send rule: funds sent after 30 minutes still land in the user's **Coinbase crypto balance**, but the sell moves to `TRANSACTION_STATUS_FAILED` and won't auto-complete [^11].

The wire names the **admin as fee payer**, not the player. Until 2026-09-14 it named the player's own wallet, which meant a Phantom player holding USDC and **zero SOL could not withdraw at all** — the one gap in Turf Monster's otherwise gasless story, met at the worst possible moment. The player still signs, because it is their USDC leaving their token account and that consent is the protection; only the fee payer changed. Because the admin's slot must then be filled, the flow gains a cosign hop and runs in four steps:

1. `POST /cdp/offramp/prepare_send` — server resolves the Coinbase destination on-chain and returns the fully **unsigned** two-signer wire (admin slot 0 = fee payer, wallet slot 1 = transfer authority; both empty).
2. Phantom signs its own slot. The client serializes with `requireAllSignatures: false` — the admin slot is still empty, so a default `serialize()` would throw.
3. `POST /cdp/offramp/cosign_send` — server re-derives the destination and amount from its own row, runs `Solana::Vault#assert_usdc_transfer_cosign_safe!` against the returned bytes, then fills the admin slot via `#cosign_usdc_transfer`, simulates the cosigned wire via `#preflight_cosigned_wire!`, and hands back the fully-signed wire only when the simulation passes. **Validate-then-cosign-then-simulate**: on reject nothing is signed or returned, no claim is taken, and the forensic reason is logged server-side but never returned to the client.
4. Client broadcasts, then `POST`s the signature to `/cdp/offramp/sent`, which verifies it on-chain before recording so the poll job can reconcile.

**Why the guard is mandatory.** The admin is the fee payer, so filling its signature slot is the house agreeing to pay for whatever bytes the client hands back. The guard is the SPL-transfer twin of the entry and create_contest cosign guards: exactly two signers, the admin in slot 0 as fee payer and the cash-out wallet in slot 1, exactly one SPL Token instruction and it is a Transfer of the exact expected amount from the wallet's own USDC ATA to the resolved destination under the wallet's own authority, only fee-capped ComputeBudget and Phantom-injected Lighthouse **assertion** instructions besides, and **no System instruction, ever**. The Lighthouse check is `Solana::Vault#assert_lighthouse_ix_safe!`, shared with the entry and create_contest guards: it admits assertion discriminators 2–17 and refuses `MemoryWrite` (0), `MemoryClose` (1), empty data, and any unknown discriminator. The memory refusal is what protects the house here: `MemoryWrite` makes the signer it names as payer fund a memory account, and the house signs this wire as fee payer, so without it a crafted cash-out could lock house SOL. The check keys on the discriminator rather than on whether an instruction names the fee payer, because the real Phantom mainnet wires the house has cosigned carry `AssertAccountInfoMulti` (6) and `AssertTokenAccountMulti` (10), and each has a variant-6 assertion on the fee payer's own post-state.

**Why the signer count is pinned.** Solana charges the fee payer 5,000 lamports for every signature the message declares, and charges it when a landing fails too. The priority half of the fee was already capped; the base half was not, so until 2026-09-17 a player could pad the cash-out wire with signer slots they filled themselves. Ten signers fit Solana's 1,232-byte packet beside a valid transfer, which raised the house's cost per failed landing from 110,000 to 150,000 lamports. `Solana::Vault#assert_cosign_signer_set!` now refuses any wire whose header does not declare exactly two signers (`signer_count_mismatch`), or whose slot 1 is not the cash-out wallet (`wallet_not_signer`). The entry and create_contest guards run the same check. Lighthouse adds instructions, never signers, so Phantom-protected wires still pass: all five real mainnet wires the house has cosigned declare exactly two signers, the house then the player, pinned byte for byte in `test/fixtures/files/phantom_mainnet_cosigned_wires.json` (pin-cashout-cosign-signer-count).

**Why the pre-flight is mandatory.** The client broadcasts the cosigned wire with `skipPreflight: true`, so no node checks it after the house signs, and a wire that fails on chain still charges its fee payer — the house. The entry and contest-create cosigns simulate before they broadcast; `Solana::Vault#preflight_cosigned_wire!` is the same check for the one cosign path that does not broadcast itself. It uses the entry path's settings (`sig_verify: false`, `replace_recent_blockhash: true`): the house pays only for a transaction that executes, and a wire with a bad signature or a dead blockhash never executes, so the program verdict is the one that protects the fee payer. It fails closed. A failed simulation, one that could not be run, one that answered nothing, and one whose answer has no `err` field all raise `PreflightRejected`, and the program error and logs go to the `ErrorLog`. The refusals that gave **no verdict** are its subclass `PreflightUnavailable`, so the player reads different copy for each: an outage gets "Solana is busy right now — please try again in a moment." (502), and a wire the program refused gets "Check that your wallet still holds the USDC, then start the cash-out again." (422). A missing `err` is refused because `sim["err"]` reads a missing key exactly like a clean `"err": null`. No conforming node omits it: agave's `RpcSimulateTransactionResult` serializes `err` with no `skip_serializing_if`, and read-only `simulateTransaction` calls to Helius and the public mainnet RPC on 2026-09-17 returned `"err": null` for a clean simulation and `"err": "AccountNotFound"` for a failing one. So the refusal should never fire on a real answer; it guards against a proxy, a truncated body, or a future shape change. The simulate-and-read-err logic is one private helper, `Solana::Vault#simulate_wire!`, shared with the entry, contest-create and multisig broadcast paths; each caller keeps its own error types and empty-answer handling, pinned in `test/services/solana/vault_simulate_callers_test.rb`.

**One cosign per row, claimed under a row lock.** `#cosign` moves the row to `sending` as soon as the house has signed a wire that passed its simulation, so a row holds at most one outstanding wire — every broadcast costs the house its fee whether the transfer succeeds or fails. That alone is not a cap on attempts: the simulation sees only failures present at cosign time, so a wire built to fail after it (a Lighthouse clock assertion, or the USDC moved out first) lands as `failed` and the rewind rule below re-arms the row. The **failed-send cap** below bounds that loop. The claim is `CdpRampTransaction#mark_sending!`, and **its return value is the cap**: when it answers false the signed wire is NOT rendered, because bytes handed out are bytes that can be broadcast. The sequence runs in two `#with_lock` holds with the simulation between them: the first decides, guards and cosigns; the second takes the claim, and only after the simulation passes. Two concurrent requests may both reach a cosign, but only one can claim, and only the claimant's bytes are rendered. Because the claim follows the simulation, a failed or interrupted simulation never leaves a row claiming a signature that was not returned. Every RPC call — the destination and send-status reads, and the simulation — happens outside both holds, so no database connection is held across a network call.

**The rewind rule — the one that sends a player's USDC twice if it is wrong.** The legitimate retry (the browser never managed to broadcast) is re-armed only on a DEFINITIVE verdict, and that verdict is `CdpRampTransaction#send_verdict` — the same one `Cdp::OfframpSendJob#verify_pending_send` uses, deliberately shared so the two paths cannot drift:

| Verdict | Meaning | Cosign endpoint |
|---------|---------|-----------------|
| `:landed` | confirmed/finalized, no err | refuse — the money moved |
| `:failed` | an on-chain err | re-arm and **count** — funds did not move, but the house paid the fee; the count that reaches the cap ends the row `failed` instead |
| `:never_landed` | absent from a **history-searched** lookup, past `BLOCKHASH_LAPSE` after `broadcast_at` | re-arm, **uncounted** — verified dead, never executed, so the house paid nothing |
| `:ambiguous` | anything else | **refuse** |

Two traps are baked into that table. First, **"no status" is not "never landed"** — an absent signature is in-flight or not-yet-indexed just as often as it is dead, and only the age of the *broadcast* separates them (hence `broadcast_at`, never `confirmed_at`: the broadcast can legally trail the user's click by minutes). Second, the lookup must be `confirm_transaction` — `getSignatureStatuses` with **`searchTransactionHistory: true`** — because a plain `getTransaction` at `confirmed` returns nothing for a merely unindexed transaction, which would read as dead and build a second full-amount transfer.

**Failed-send cap: 3 failed landings per cash-out** (`CdpRampTransaction::MAX_FAILED_SENDS`, set 2026-09-17 by cap-cashout-failed-send-rearms). The house pays the fee on a Phantom cash-out wire that lands and fails, and a player can build one that passes the pre-flight and fails on landing — a Lighthouse `AssertSysvarClock` on a slot a few blocks ahead is enough. No allow-list closes that, because any pass-then-fail condition works, so the bound lives on the row. Each `:failed` verdict is counted in `failed_send_count` by `CdpRampTransaction#rearm_after_failed_send!`, under the same row lock as the rewind. The first two re-arm as before. The third ends the row `failed`, and the house signs nothing more for it. Each counted landing, and the cap itself, writes an `ErrorLog` (`Cdp::OfframpSendsController::FailedSendLanded`) targeting the row with the player as parent, so the bleed is visible in the error log and Sentry. Every send endpoint then answers the capped row with "This cash-out failed on Solana too many times, so we've closed it. No USDC was sent. Please start a new cash-out." `:never_landed` re-arms are not counted: those sends never executed, so they cost the house nothing, and they are the legitimate retry when the browser never broadcast. A re-arm rolled back by a guard refusal is not counted either.

- **Why 3.** No other cash-out retry constant exists to match, so this is the conservative pick. A player whose first send fails for an honest reason still gets two more tries, and a hostile row costs the house at most three failed landings, 330,000 lamports (0.00033 SOL) with the default fee settings. Each landing costs at most 110,000 lamports: 2 signatures x 5,000 lamports base fee (the signer count is pinned at two, `Solana::Vault::COSIGN_SIGNER_COUNT`) plus the 100,000-lamport priority fee ceiling (`COSIGN_FEE_MARGIN`). Before the signer pin a padded ten-signer wire cost 150,000 per landing, so 450,000 for the row. The bound is per row, so starting a fresh cash-out resets it; each fresh cash-out costs the player a new Coinbase sell session and stays under the `cdp_offramp_send/user` throttle.
- **To change it,** edit `MAX_FAILED_SENDS` in `app/models/cdp_ramp_transaction.rb`. The tests read the constant, except `the cap is three failed sends per cash-out row`, which pins the value and must move with it. The comparison is `>=`, so lowering the cap also closes live rows already counted past it the next time they fail.
- **Only the Phantom cosign path is capped.** `Cdp::OfframpSendJob` (managed mode) still rewinds with the uncounted `#reset_failed_send!`. It builds and signs its own wire, sends it with the node's pre-flight on, and re-checks the balance before every attempt, so a player cannot shape a pass-then-fail wire there.

**Rate limit.** `POST /cdp/offramp/cosign_send` and `/cdp/offramp/prepare_send` are capped at 10/min per user (`cdp_offramp_send/user` in `config/initializers/rack_attack.rb`). A new POST route defaults to EXEMPT there, and this one spends `SOLANA_ADMIN_KEY` — the same wallet that pays for entries, mints and payouts.

**Minimum withdrawal: $0.99** (`Solana::Vault::MIN_WITHDRAWAL_BASE_UNITS`, set 2026-09-14). Since the house now pays the fee on **both** cash-out paths, a withdrawal costs the house real SOL whether it succeeds or fails on-chain — measured at **20,000 lamports (0.00002 SOL)** per cash-out with the current defaults (2 signatures x 5,000 lamports base fee, plus 50,000 micro-lamports/CU x 200,000 CU priority). The floor keeps a withdrawal worth more than the fee carrying it and closes the dust-withdrawal vector. It is asserted in **both builders** (`#build_user_usdc_transfer` and `#build_user_usdc_transfer_unsigned`), not only in the controller, so a future caller cannot route around it; the controller and `Cdp::OfframpSendJob` refuse earlier with copy that names the floor. Deliberately not ENV-overridable: it is a user-facing money boundary whose copy quotes it.

## 11. Status polling (Sidekiq)

- **`Cdp::OfframpPollJob`** — `GET /onramp/v1/sell/user/{partner_user_ref}/transactions?page_size=50` (page_size **defaults to 1** — always pass it) [^10][^13]. Per docs: "avoid polling immediately after generating the URL; wait until the send transaction is created… using exponential backoff" [^11] — **start at session-mint time** (first poll ~60s after the URL is handed out, while the user is still inside the widget), then 10s → 30s → 1m → 2m → 5m, stop at terminal status or deadline + grace. The return-page hit *(re-)schedules* the same idempotent loop but must never be the only trigger — per the Risks section the redirect is broken by design as a signal (un-allowlisted domain or a closed tab silently drops it while the transaction completes), and offramp `to_address` discovery has to run regardless or the 30-minute cashout window lapses with no send. Status enum (API reference): `TRANSACTION_STATUS_CREATED | EXPIRED | STARTED | SUCCESS | FAILED`; the guide page lists only STARTED/SUCCESS/FAILED — handle unknown values defensively [^13]. Response fields used: `to_address`, `sell_amount`, `from_address`, `tx_hash`, `coinbase_fee` (null unless offramping to fiat). `transactions[]` is reverse chronological; with our per-session `partner_user_ref` the first row is ours [^13].
- **`Cdp::OnrampPollJob`** — `GET /onramp/v1/buy/user/{partner_user_ref}/transactions?page_size=50`. Statuses: `ONRAMP_TRANSACTION_STATUS_IN_PROGRESS | SUCCESS | FAILED`; `partner_user_ref` in the response "corresponds to the partnerUserRef parameter… in the Onramp URL" [^14]. On SUCCESS: update the ramp row and push a balance refresh via `window.StateFanout` (one new `register()` call).
- Both: upsert by `transaction_id`, idempotent, structured logging.

## 12. Webhooks (phase 2 — polling stays the authoritative baseline)

Event types: `onramp.transaction.{created,updated,success,failed}` and `offramp.transaction.{created,updated,success,failed}` [^12]. Registration is **CDP-CLI-only** (operator step). Payloads are camelCase (`eventType`, `status`, `paymentTotal{currency,value}`, `txHash`, `transactionId`, `partnerUserRef`) [^12]. `Webhooks::CdpController#create` modeled on the existing `Webhooks::StripeController`: verify signature per the standard CDP webhook verification flow (`/webhooks/verify-signatures`) with `CDP_WEBHOOK_SECRET`, upsert by `transactionId`, trigger the same handlers as the poll jobs, return 200 fast. Full payload schema + retry policy are not formally documented — keep polling running regardless.

## 13. State/country gating (`Cdp::Catalog`)

- `GET /onramp/v1/buy/config` (no params) → `countries[] { id, subdivisions[] (US states only), payment_methods[] }`; `GET /onramp/v1/sell/config` — same shape for offramp [^15]. Docs: "call this API periodically and cache the response" [^15].
- `GET /onramp/v1/buy/options?country=US&subdivision=XX&networks=solana` — **subdivision is REQUIRED for country=US** ("certain states (e.g., NY) have state specific asset restrictions"); confirm USDC appears in `purchase_currencies` with a Solana network entry + read min/max per payment method. `GET /onramp/v1/sell/options?country=US&subdivision=XX&networks=solana` → `cashout_currencies[].limits` + `sell_currencies` for the sell side [^16].
- Implementation: `Rails.cache.fetch(..., expires_in: 12.hours)` **plus per-request `@ivar ||=` memoization** (dev null_store no-ops Rails.cache — existing house pattern). Gate the Buy/Cash-out buttons with the geo session `Studio::GeoDetection` resolves (country + subdivision); disable with an explainer when unsupported.
- At integration time, verify the network slug Solana reports in options/config responses (`"solana"` vs `"solana-mainnet"`-style strings appear in different doc examples) and whether buy-config nests under a `data` key [^15].

## 14. Frontend

- "Buy USDC" / "Cash out" buttons (wallet + balance surfaces), Alpine, gated on `AppFlags.cdp_ramp?` + geo + (sell) USDC balance > 0.
- Click → authedFetch POST to our session endpoint → `window.open(url, "_blank")` popup or new tab. **Never iframe — explicitly unsupported** [^11]. Hosted URLs break inside WebViews (passkeys/WebAuthn) — fine for our plain web app, note for any future wrapper [^11].
- Offramp pre-flight modal must state up front: **a Coinbase account with a linked payout method is required (guest checkout is not supported for fiat withdrawal)** [^11], and the 30-minute send window.
- Onramp copy should assume Coinbase login: guest checkout via the hosted widget is **deprecated June 30, 2026** [^20]. Fee transparency: spread + Coinbase fee on order preview, 2.5% card / 0.5% ACH, network fee estimate; zero-fee USDC only via rep-gated subsidy program [^11].

## 15. Testing

- Unit (minitest + WebMock): JWT round-trip decode (alg/kid/nonce/claims incl. `uri`), 64-byte key validation, URL builders (required-param enforcement, <50-char ref), poll-job state machine, managed-send guards, catalog gating. Grep `test/test_helper.rb` before adding helpers.
- Sandbox `https://pay-sandbox.coinbase.com/?sessionToken=...` covers **only the guest-checkout debit-card flow** (card `4242 4242 4242 4242` = success, any other 16-digit = decline, any 6-digit SMS code) — limited value given the deprecation [^21]. Production widget hidden mock: click the word "Secured" 10 times → Debug Menu → "Enable Mocked Buy and Send" [^21].
- **Real end-to-end (especially offramp + the `to_address` question) is mainnet-only with real funds** — plan a small operator-run smoke test (see operator steps). The `"sandbox-"` `partnerUserRef` prefix applies only to the v2 sessions API [^17].

---

## Operator steps (CDP portal — human-only)

1. **Account + project.** Go to https://portal.cdp.coinbase.com and sign in / create the CDP account. Create a project (or pick one from the **top-left project dropdown**). Click the **gear icon** → project details → copy the **Project ID** into 1Password (not needed for the REST JWT auth, but webhook subscriptions and SDK configs reference it).
2. **Secret API Key.** Go to https://portal.cdp.coinbase.com/projects/api-keys → select the **Secret API Key** tab — NOT Client API Key ("Client API Keys are for client-side JSON-RPC requests and will not work with Onramp/Offramp REST APIs"). Create key: nickname `turf-monster-ramp-prod`, signature algorithm **Ed25519 (recommended)**, skip IP restrictions (Heroku dynos have no stable egress IPs). Copy the **key ID (UUID)** and **secret (base64)** from the modal.
3. **Store the secret.** 1Password entry (per existing OPSEC pattern), then locally `bin/setup-cdp-key` (clipboard → .env), and `heroku config:set CDP_API_KEY_ID=… CDP_API_KEY_SECRET=… -a turf-monster-mainnet` via the pbpaste secret-paste workflow — never paste the secret inline into an agent-visible terminal.
4. **Domain allowlist.** Portal → **Payments → Onramp & Offramp** (https://portal.cdp.coinbase.com/products/onramp) → Domain Allowlist → add `https://turfmonster.media` and keep `https://app.turfmonster.media` until all legacy links/provider callbacks are migrated. Set the optional **Display Name** ("Turf Monster") — it appears on the order preview and the post-purchase redirect countdown/button.
5. **Localhost dev story.** Try adding `http://localhost:3100` to the same allowlist. Docs only require allowlisting for *production* redirect URLs and the quickstart uses a bare localhost redirectUrl in dev; if the portal rejects localhost, dev still works — the post-transaction redirect is just silently skipped (the transaction itself completes). Report which outcome you got so the build can finalize the dev return-page story.
6. **Trial mode.** Nothing to click — new integrations start in trial mode automatically. Note: no numeric trial limits are published anywhere.
7. **Full-access application.** Complete the onboarding form at https://support.cdp.coinbase.com/onramp-onboarding (app: turfmonster.media, USDC on Solana, hosted integration). Record whatever trial limits / review timeline they state — both are undocumented.
8. **Zero-fee USDC.** There is no self-serve link; the FAQ says zero-fee USDC onramping is a subsidy program for select partners — "Contact your account representative." Raise it in the onboarding form notes and/or with CDP support/Discord, and record the answer.
9. **Webhooks (only when phase 2 starts).** From the Mac: `npm install -g @coinbase/cdp-cli`, auth with `cdp env live --key-file ./cdp_api_key.json`, then create the subscription for `onramp.transaction.*` + `offramp.transaction.*` targeting `https://turfmonster.media/webhooks/cdp`. The 201 response contains `metadata.secret` **once** — store in 1Password + `heroku config:set CDP_WEBHOOK_SECRET=…`.
10. **Launch flag.** When the build + smoke test are ready: `heroku config:set ENABLE_CDP_RAMP=true -a turf-monster-mainnet`. Unset it as the kill-switch.
11. **Mainnet smoke test (operator-run, real money).** FIRST item, before any money moves: verify a GET **with query params** (e.g. `GET /onramp/v1/buy/options?country=US&subdivision=CA&networks=solana`) returns 200 against the live API — this proves the JWT `uri`-claim path-only binding (§3); a query-signing bug 401s every poll/catalog call while the query-less `POST /onramp/v1/token` keeps working. Then one small buy (~$10 USDC, Coinbase login) to your own wallet, then one small sell from a managed-wallet test user using your Coinbase account with a linked bank. This is the only way to verify the offramp `to_address` semantics (owner address vs token account), the redirect behavior, and end-to-end status polling — there is no testnet for onramp/offramp.

## Risks

- **A balance under $0.99 can never be withdrawn.** The minimum-withdrawal floor is absolute, so a player whose ENTIRE remaining balance sits below it has no cash-out path at all. Accepted deliberately — the amount is under a dollar and the on-chain rent and fees to move it exceed it — but the UI should say so where a small balance is shown, rather than letting it arrive as a support ticket.
- Offramp hard-requires a Coinbase account with a linked payout method — "Guest checkout is not supported for fiat withdrawal." Some players simply cannot cash out via this path; the UI must say so before they start.
- Guest Checkout via the hosted widget (debit card / Apple Pay without a Coinbase account) is deprecated June 30, 2026. Onramp must be designed as Coinbase-login-first; supporting wallet-less buyers later means a separate Headless Onramp build.
- No testnet: onramp delivers real mainnet USDC and offramp moves real funds. The offramp loop (to_address discovery + send + settlement) can only be verified with real money on prod.
- Offramp 30-minute send window: funds sent late still land in the user's Coinbase crypto balance but the sell goes TRANSACTION_STATUS_FAILED and never auto-completes — guaranteed support tickets without an aggressive countdown UX and clear copy.
- Managed-wallet offramp is a server-signed movement of user funds to an externally supplied address. Requires a fresh explicit user confirmation, amount/destination guards, deadline cut-off, and verify-before-retry (a blind retry after an RPC timeout double-sends USDC irrecoverably).
- redirectUrl is UX-only: no documented query params on return, and an un-allowlisted domain makes the redirect silently no-op while the transaction still completes — any confirmation logic hung off the redirect is broken by design. Monitor returned_at rates to catch allowlist regressions.
- Trial-mode limits are completely unpublished (the $500/week / 15-lifetime figures are Guest Checkout USER limits, a different concept) and the full-access review timeline is unknown.
- clientIp tension on Heroku: docs say never trust X-Forwarded-For, but Heroku only delivers the client IP via XFF; we send request.remote_ip and accept the documented anti-pattern.
- Casing/naming traps: camelCase request bodies, snake_case v1 responses, camelCase webhooks; partnerUserRef (URLs + status APIs) vs partnerUserId (sell quote API). Easy to ship a silent correlation-breaking mismatch.
- jwt-eddsa is a third-party gem (anakinj) on the signing path for the CDP secret key — pin the version and watch updates.
- No documented rate limit for POST /onramp/v1/token — keep our own per-user throttle on the mint endpoints and handle 429 rate_limit_exceeded defensively.
- Phantom-mode offramp has a mandatory manual post-redirect send step — expect drop-off and stranded EXPIRED/CREATED rows; needs abandoned-state handling and re-entry UX within the 30-minute window.
- Phantom/Blowfish previously flagged turfmonster domains as malicious (de-list in progress) — Phantom may show scare warnings on the offramp send signature, killing conversion for web3 users until the de-list lands.
- User-facing fees (spread + Coinbase fee, 2.5% card / 0.5% ACH, network fee) make small buys expensive; zero-fee USDC is rep-gated — pricing copy must not promise fee-free until granted.
- Token-minting endpoint liability: Coinbase explicitly holds the developer liable for misuse of an improperly secured session-token endpoint — auth gating, no wildcard CORS, and rate limiting are compliance requirements, not nice-to-haves.

## Open questions (resolve during build/smoke test)

1. clientIp required vs optional — two docs pages conflict. Build sends request.remote_ip always; confirm against the live API.
2. Offramp status enum conflict: API reference says CREATED | EXPIRED | STARTED | SUCCESS | FAILED; the guide lists only STARTED/SUCCESS/FAILED; the FAQ says late sends go FAILED. Confirm which status appears first after "Cash out now" (CREATED expected — it gates our send trigger) and when EXPIRED vs FAILED is set.
3. Solana to_address semantics for offramp sends: owner address (derive USDC ATA) vs SPL token account (use directly)? No doc says. Resolve on the first mainnet sell BEFORE enabling managed-wallet auto-send for real users.
4. No verbatim session-token example with blockchains:["solana"] exists in docs — verify the token mints and the widget shows USDC-on-Solana on the first real call.
5. What (if anything) is appended to redirectUrl on completion — **ANSWERED (2026-06-10, empirical):** Coinbase appends `?onramp_result=success` on a successful buy (observed on a localhost return). Other result values unverified; return pages still key everything off partner_user_ref polling (unchanged).
6. Can localhost be added to the Onramp/Offramp domain allowlist? **ANSWERED (2026-06-10, empirical):** the localhost redirect fired and landed on `/cdp/onramp/return` in dev — local return-page testing works.
7. Trial-mode numeric limits + full-access review timeline — capture during operator onboarding. **PARTIALLY ANSWERED (2026-06-10, empirical):** trial mode caps GUEST checkout at **$5/week** (widget copy: "Buy up to $5/week or create a Coinbase account for higher limits") — below a single $19 entry, so full access is a launch blocker for wallet-less buyers. Normal (non-trial) guest cap is $500/week. Coinbase-account buys have higher limits even in trial (per the widget's own upsell). Full-access review timeline still unknown.
8. Network slug naming in config/options responses ("solana" vs "solana-mainnet") and whether buy-config nests under a "data" key — verify against live GET /onramp/v1/buy/options?country=US&networks=solana before wiring Cdp::Catalog parsing.
9. defaultPaymentMethod accepted string set and defaultAsset format (ticker "USDC" vs Coinbase asset UUID) — test with ticker first.
10. Whether POST /onramp/v1/token shares the quote APIs' 10 req/s throttle; exact error shape for a reused/expired session token; whether the 5-minute TTL runs creation→URL-open or longer.
11. Is the nonce JWT header strictly enforced server-side? Always sending SecureRandom.hex(16). Also unverified: the downloaded API key file's JSON shape, and whether ECDSA still appears in the portal key-creation flow (the zero-new-gem fallback depends on it).
12. Confirm no v2 sessions equivalent ships for OFFRAMP before building (v1 token flow is the documented path).
13. Offramp fee schedule for USDC — verify coinbase_fee on a real POST /onramp/v1/sell/quote before writing cash-out fee copy.
14. Webhook payload full schema + delivery retry policy — undocumented; whether Buy/Sell Options min/max differ between trial mode and full access.
15. Payout timing to bank/PayPal after a successful sell (consumer help says ACH 1–5 business days) — needed for cash-out expectations copy.

---

### Source footnotes

[^1]: https://docs.cdp.coinbase.com/api-reference/rest-api/onramp-offramp/create-session-token and https://docs.cdp.coinbase.com/onramp/reference (Session Token API)
[^2]: https://docs.cdp.coinbase.com/get-started/authentication/jwt-authentication (official Ruby example); jwt 3.x EdDSA extraction: https://github.com/anakinj/jwt-eddsa, https://github.com/jwt/ruby-jwt
[^3]: https://docs.cdp.coinbase.com/get-started/authentication/cdp-api-keys and https://docs.cdp.coinbase.com/api-reference/v2/authentication
[^4]: https://docs.cdp.coinbase.com/onramp/introduction/quickstart
[^5]: https://docs.cdp.coinbase.com/onramp/reference (token lifetime warning)
[^6]: https://docs.cdp.coinbase.com/onramp/coinbase-hosted-onramp/generating-onramp-url and https://docs.cdp.coinbase.com/onramp/reference (Onramp URL Parameters)
[^7]: https://docs.cdp.coinbase.com/onramp/security-requirements
[^8]: https://docs.cdp.coinbase.com/onramp/offramp/generating-offramp-url and https://docs.cdp.coinbase.com/onramp/reference (Offramp URL Parameters)
[^9]: https://docs.cdp.coinbase.com/api-reference/rest-api/onramp-offramp/create-sell-quote and https://docs.cdp.coinbase.com/onramp/offramp/generating-quotes
[^10]: https://docs.cdp.coinbase.com/onramp/offramp/offramp-integration-guide
[^11]: https://docs.cdp.coinbase.com/onramp/additional-resources/faq
[^12]: https://docs.cdp.coinbase.com/webhooks/onramp
[^13]: https://docs.cdp.coinbase.com/api-reference/rest-api/onramp-offramp/get-offramp-transactions-by-id and https://docs.cdp.coinbase.com/onramp/offramp/transaction-status
[^14]: https://docs.cdp.coinbase.com/onramp/core-features/transaction-status
[^15]: https://docs.cdp.coinbase.com/api-reference/rest-api/onramp-offramp/get-buy-config, .../get-sell-config, https://docs.cdp.coinbase.com/onramp/coinbase-hosted-onramp/countries-&-currencies
[^16]: https://docs.cdp.coinbase.com/api-reference/rest-api/onramp-offramp/get-buy-options and .../get-sell-options
[^17]: https://docs.cdp.coinbase.com/api-reference/v2/rest-api/onramp/create-an-onramp-session
[^18]: https://docs.cdp.coinbase.com/get-started/changelog (Session Token Upgrade, effective 2025-07-31)
[^19]: https://docs.cdp.coinbase.com/onramp/additional-resources/layer-2-networks
[^20]: https://docs.cdp.coinbase.com/onramp/coinbase-hosted-onramp/overview (Guest Checkout deprecation banner)
[^21]: https://docs.cdp.coinbase.com/onramp/additional-resources/sandbox-testing
