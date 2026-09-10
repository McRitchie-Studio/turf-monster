# Rate Limiting

> **Status:** design / pre-build (2026-06-01). This is the spec for a two-tier
> rate-limit subsystem to be built in turf-monster and then promoted into
> studio-engine for the rest of the ecosystem. Nothing here is implemented yet
> except the existing rack-attack throttles described under "Current state."

## Goal

Two categories of rate limiting, with friendly, **always-visible** feedback (a
modal, never a silent no-op), built so the mechanism can be lifted into
`studio-engine` and reused by other apps with only per-app config.

- **Tier 1 — General.** A *forgiving* cap on ordinary interactive writes
  (entering a contest, sending a chat message, toggling picks). Metric: calls
  per 60 seconds. Exceed it → a friendly **global 60s wait modal** that counts
  down and auto-resets. This is a flood backstop, not a gate — the threshold is
  high enough that a normal human never trips it.
- **Tier 2 — Auth.** A *strict, escalating* ladder for the email/auth surface
  (magic-link the canonical case). Resends are paced; abuse escalates; every
  state is explained by a modal.

## Current state (what exists today)

`config/initializers/rack_attack.rb` (OPSEC-019, rack-attack 6.8.0). **27**
`throttle` blocks, no safelists/blocklists, a custom 429 responder, and a
`throttle.rack_attack` WARN logger.

**Re-derived from the file, 2026-09-07.** This table read `17` and listed
seventeen rows while the initializer already held twenty-six — the three
non-Stripe webhooks, the CDP and PayPal/Coinflow/Aeropay checkouts,
`check_funding/ip` and `general/ip` had all landed without an entry here. A
limits table that is short by a third is worse than none: the gaps read as
"unthrottled", which is the one thing this page exists to answer. Re-derive it
rather than extend it:

```bash
grep -n '^  throttle("' config/initializers/rack_attack.rb
```

| Bucket | Throttle | Limit | Key |
|---|---|---|---|
| Auth | `login/ip` | 10 / min | ip |
| Auth | `login/email` | 5 / min | downcased email param |
| Auth | `solana_nonce/ip` | 30 / min | ip |
| Auth | `solana_verify/ip` | 10 / min | ip |
| Auth | `solana_report_failure/ip` | 20 / min | ip (unauthenticated; writes an `error_logs` row per call) |
| Auth | `link_solana/ip` | 5 / min | ip |
| Auth | `signup/ip` | 5 / min | ip |
| Auth | `magic_link/ip` | **5 / hour** | ip |
| Auth | `magic_link/email` | **3 / hour** | downcased email param |
| Auth | `email_verification/ip` | 3 / hour | ip |
| Money | `faucet/ip` | 5 / hour | ip |
| Money | `airdrop/ip` | 5 / hour | ip |
| Money | `stripe_checkout/ip` | 10 / min | ip (covers `/tokens/stripe_checkout` + `/wallet/stripe_deposit`) |
| Money | `paypal_checkout/ip` | 10 / min | ip (`/tokens/paypal_order` + `/tokens/paypal_capture`) |
| Money | `coinflow_checkout/ip` | 10 / min | ip (`/tokens/coinflow_order`) |
| Money | `aeropay_checkout/ip` | 10 / min | ip (`/tokens/aeropay_order`) |
| Money | `cdp_sessions/user` | 10 / min | session user id (`/cdp/onramp_sessions` + `/cdp/offramp_sessions`) |
| Money | `wallet_withdraw/ip` | 5 / min | ip |
| Money | `webhooks/stripe` | 100 / min | ip |
| Money | `webhooks/paypal` | 100 / min | ip |
| Money | `webhooks/coinflow` | 100 / min | ip |
| Money | `webhooks/aeropay` | 100 / min | ip |
| Interactive | `chat_messages/ip` | 40 / min | ip (regex `/contests/:id/messages`) |
| Interactive | `prepare_entry/ip` | 30 / min | ip (regex `/contests/:id/prepare_entry`) |
| Interactive | `check_funding/ip` | 30 / min | ip (regex `/contests/:id/check_funding`) |
| Interactive | `update_username/ip` | 10 / min | ip |
| Interactive | `general/ip` | 90 / 60s | ip (tier-1 limiter — toggle_selection / enter / clear_picks) |

Key facts that constrain the design:

- **Custom responder** (`rack_attack.rb:127-139`): HTTP **429**, `Content-Type:
  application/json`, `Retry-After: <period seconds>`, body
  `{ error, retry_after }`. The new contract extends this body.
- **Plain `throttle` is a fixed window** — no escalation, no idle-reset.
  rack-attack 6.8.0 ships `Fail2Ban`/`Allow2Ban` (ban-after-N-strikes) but
  **neither expresses "clears after 5 minutes of inactivity."** Tier 2 therefore
  needs custom counter logic.
- **Counters live in `Rails.cache`** — Redis in prod (Lazarus audit #11 moved it
  off the per-dyno `:memory_store` that made limits effectively off) and dev;
  **`:null_store` in test**, and **`Rack::Attack.enabled = false` in test env**.
- **Cache key prefix is the literal `rack::attack:`** (double colon). The e2e
  reseed (`TestController#reseed` → `Rails.cache.delete_matched("rack::attack:*")`)
  and the manual dev clear both match that exact string. Any new counter that
  must be swept between e2e specs has to use the same prefix.
- The magic-link GET confirmation page is inert, and the POST consume route is
  intentionally un-throttled; CSRF plus the single-use signed token do the work.
- The one existing *stateful* limiter is `MessagesController#posting_too_fast?`
  (DB-backed, 5 msgs / 15 s per user) — the model for any future per-user logic.

## Tier 1 — General interactive limiter

A single new throttle, **strict allowlist** (never a denylist):

```
throttle("general/ip", limit: <~90>, period: 60.seconds) do |req|
  req.ip if write_verb?(req) && GENERAL_INTERACTIVE.match?(req.path)
end
```

- Fires **only** for state-changing verbs (POST/PATCH/PUT/DELETE) **and** an
  explicitly enumerated set of governed paths. Returns `nil` (uncounted)
  otherwise, so **the default is exempt** — a new POST route added later is not
  silently swept into the general cap.
- **Governed** (genuine user writes, low legit frequency): `toggle_selection`,
  `pick`, `enter`, `clear_picks`, the entry-edit PATCH, plus the faucet (see
  Test surface). Account form writes (`save_profile`, `unlink_google`,
  `set_inviter`) are **excluded from v1** — they are Turbo form / `button_to`
  submits, not `fetch`, so the client interceptor can't surface their modal
  (see Risk 1). Revisit only if prod WARN logs show real hits.
- **Excluded / deferring to their own throttle:** every endpoint that already
  has a dedicated rule (chat, prepare_entry, update_username, link_solana,
  stripe_checkout, wallet_withdraw, withdraw, login, signup, solana
  nonce/verify, magic_link, email_verification). The general cap must never
  loosen or duplicate these.
- **Exempt by construction** (all GETs / realtime / health): every raw page GET
  (incl. Turbo Drive speculative prefetch on hover), `GET /tokens/status` and
  `/tokens/processing` (1.5 s pollers), `leaderboard_poll` (90 s),
  `session_state`/`session_refresh`/`wallet/sync` (rehydrate), `/up`,
  `/geo/check`, `/cable` (WebSocket), `POST /webhooks/stripe` (external
  callback, keeps its 100/min), `/assets/*`. The write-verb gate makes the GET
  pollers structurally exempt; `/webhooks/stripe` must be explicitly omitted
  from the allowlist.
- **Threshold ≥ 90/60s** to start (tune from prod WARN logs). One "confirm
  entry" gesture can fan out to ~7 governed writes (`replaySelectionsToServer`
  replays up to 6 `toggle_selection` then `enter`), so the cap must clear that
  comfortably.
- **Reset:** a fixed 60s window — exactly "resets after 60 seconds."

On exceed → the `rate-limit-general` modal: a friendly "Easy there — give it a
sec" card with a live 60s countdown (from `Retry-After`) that auto-closes and
re-enables at zero. Dismissible (it's a soft cap).

## Tier 2 — Auth escalation ladder

rack-attack can't express idle-reset, so the ladder state lives in a custom
`RateLimit::AuthLadder` (Rails.cache-backed) that a custom rack-attack matcher
consults. Keyed per the existing `magic_link/email` discriminator (downcased
email).

| Stage | Behavior |
|---|---|
| **0 — normal** | First **3** requests allowed, paced by a **60s** cooldown each. Each delivers + shows the modal-swap "fresh link sent" confirmation. |
| **1 — escalated** | The 4th request inside the window blocks and starts a **5-minute idle timer**. **Each new attempt re-arms the 5 minutes** — so the lock clears after 5 minutes *without* a request, not 5 minutes after the trip (`gate = now - last_attempt_at >= 5.minutes`). Shows the explanatory wait modal. |
| **ceiling** | Independent **hard hourly cap (~12/hr)** as the anti-mailbox-bombing backstop (the email field is attacker-controlled). Hitting it returns `stage: "ceiling"`, `retry_after` = remainder of the hour. |

Config defaults (all tunable): `soft_limit 3`, `soft_window 60s`,
`escalation_idle_reset 300s`, `hard_ceiling 12`, `hard_period 1.hour`.

- **v1 scope:** `magic_link` + `email_verification` (the outbound-email
  surfaces). `login`/`signup`/`solana_verify` keep their existing simple
  throttles unless we decide to escalate them later.
- **Nothing silent:** stage-0 allowed → success + confirmation swap; stage-1 /
  ceiling → 429 + explanatory modal.
- **Cache keys MUST use the exact `rack::attack:` prefix** (or be added to
  `TestController#reseed` + e2e globalSetup) so ladder state is swept between
  e2e specs — otherwise the cross-spec throttle-pollution flake returns.

## Response contract

Extend the custom `throttled_responder`. Always **429**. Headers:
`Retry-After: <seconds>` (kept) plus a new `X-RateLimit-Tier: general | auth`.
JSON body:

```json
{ "error": "...", "tier": "general|auth", "scope": "<throttle name>", "retry_after": <int>,
  "stage": "soft|escalated|ceiling",        // tier 2 only
  "reset_at": <absolute epoch seconds> }    // tier 2 only
```

- `tier` is derived from the matched throttle name by prefix convention
  (`general/*` → general; ladder-owned `magic_link/*`, `email_verification/*` →
  auth). The ladder writes `stage` + `reset_at` into `req.env` before the
  responder runs.
- **`reset_at` is an absolute epoch** so the client countdown is correct across
  a page reload (computes `reset_at - now`, not a relative `Retry-After` that a
  reload would restart at 5:00).

## Client UX

- **One global 429 interceptor.** Today `authedFetch` (in `solana_utils.js`,
  `window.authedFetch`) is the single wrapper that intercepts **401 → login
  modal**. The 429 branch lives right next to it: parse the body (fall back to
  `X-RateLimit-Tier`), then open `rate-limit-auth` (with `{ resetAt, stage }`)
  or `rate-limit-general` (with `{ cooldownSeconds }`) via
  `Alpine.store('modals')`. Returns `null` like the 401 contract so callers
  `if (!resp) return;`. A debounce guard (mirroring `_sessionExpiredHandled`)
  prevents modal-stacking on a burst of parallel 429s.
- **Two new modal partials** registered in the layout host
  (`application.html.erb`), each a single-root `<template x-if>` (honor the
  single-root rule), reusing `modals/blocks/_card_header`:
  - `modals/_rate_limit_general` — countdown from `Retry-After`, auto-close at 0.
  - `modals/_rate_limit_auth` — countdown derived from `reset_at` (reload-safe).
- **Resend modal-swap feedback** reuses the existing
  `$store.modals.advance()`/`swap()` directional-slide API: each successful
  resend swaps to a "sent again" confirmation; a 429 swaps to `rate-limit-auth`.
  **Prerequisite (Risk 2):** `postMagicLink` and `sendVerificationEmail` are
  bare `fetch()` today with their own inline error UX — they must be migrated
  onto `authedFetch` with the `if (!resp) return;` short-circuit *before* wiring
  the swap, or the interceptor double-handles and races their inline error.

## Test surface — the Mint USDC faucet (operator's playground)

The faucet is the chosen manual-test surface because it's a single button you
can hammer. To make it a *fast-reset* test of the tier-1 wait modal:

1. **Wire the faucet client call through the interceptor.** Every Mint-USDC
   path today bypasses `authedFetch`: `faucet/show.html.erb:68` (bare fetch),
   `contests/new.html.erb:235` ("Mint $500 Test USDC" recovery, bare fetch),
   `wallets/show.html.erb:117` (`button_to`). At minimum the public
   `/faucet` page's fetch must go through the interceptor so its 429 pops the
   global wait modal.
2. **Give the faucet a fast tier-1-shaped limit** (e.g. ~3–5 per 60s) emitting
   the `tier: "general"` contract → modal + 60s countdown → resets in a minute →
   repeat, cheap and fast. The existing **`faucet/ip` 5/hour money cap stays as
   the real backstop.**

This makes Mint USDC exercise the exact modal + interceptor + countdown
machinery tier-1 ships on. **Phase 1 is not "done" until this button
demonstrates the wait modal end-to-end.**

## Studio-engine extraction

**Into `studio-engine` (shared, app-agnostic):**

1. A **RateLimit DSL** — `RateLimit.general_throttle(rack_attack, limit:,
   period:, allowlist:)` and `RateLimit.auth_ladder(rack_attack, scope:, key:,
   soft_limit:, soft_window:, escalation_idle_reset:, hard_ceiling:,
   hard_period:)` so an app's `rack_attack.rb` is a few declarative calls.
2. `RateLimit::AuthLadder` — the cache-backed idle-reset + ceiling state machine
   (pure mechanism, no app paths baked in).
3. The **discriminated responder builder** (`RateLimit.responder`) emitting the
   tier/stage/reset_at contract.
4. The **client interceptor** — the canonical `authedFetch`/global-fetch wrapper
   with the 401 + 429 branches (today it lives in turf-monster's
   `solana_utils.js`; the extraction pulls the wrapper up).
5. The two modal partials — apps override copy via the standard app-wins view
   path, exactly like `_navbar` / `sessions/new`.

**Stays per-app (config via `Studio.configure`):** the concrete limit/period
numbers, the `GENERAL_INTERACTIVE` allowlist (every app's write surface
differs), the exempt list, and which auth endpoints opt into the ladder.

```ruby
# config/initializers/studio.rb (consuming app)
config.rate_limit_general      = { limit: 90, period: 60, allowlist: [...] }
config.rate_limit_auth_ladders = { magic_link: { key: :email, soft_limit: 3, ... },
                                    email_verification: { ... } }
```

**Boundary caveats (Risk 5):** `_card_header` is app-local today (decide whether
it too is promoted); keep the new partials at the app's existing `modals/` path
for Phases 1–2 (don't fork a `studio/modals/blocks` tree yet); the layout-host
`<template x-if>` registration + single-root discipline are **required per-app
glue**, not engine-provided.

## Build phases

1. **Phase 1 — Tier 1 + the faucet playground (turf-monster, shippable).**
   `general/ip` strict-allowlist throttle + EXEMPT-by-default; extend the
   responder (`tier: general`, `X-RateLimit-Tier`); add the 429 branch to
   `authedFetch` + `modals/_rate_limit_general`; **wire the public faucet
   through the interceptor + give it a fast test limit.** Acceptance: Mint USDC
   demonstrates the wait modal; a curl/test matrix proves pollers, webhooks,
   `/cable`, `/up`, `/geo/check`, and all GETs are **not** counted and the
   dedicated throttles still fire at their own limits.
2. **Phase 2 — Tier 2 auth ladder (turf-monster, shippable).** Build
   `RateLimit::AuthLadder` (soft window + 5-min idle reset + 12/hr ceiling);
   **first migrate `postMagicLink` + `sendVerificationEmail` onto `authedFetch`
   with `if(!resp) return;`**; custom matcher for `magic_link` (+
   `email_verification`) stashing `stage`/`reset_at`; `modals/_rate_limit_auth`
   with the reset_at-absolute countdown + swap-on-resend. Pin ladder cache keys
   to the `rack::attack:` prefix (or extend the reseed) **in this phase**.
3. **Phase 3 — Tests + coverage.** Unit-test `AuthLadder` directly with an
   injected `MemoryStore` (window math, idle re-arm, ceiling); one integration
   test with `Rack::Attack.enabled = true` + MemoryStore proving the matcher
   wires `stage`/`reset_at` into `req.env`; add the ladder-prefix clear to e2e
   globalSetup; migrate the long tail of bare `fetch()` to `authedFetch` (or
   install a Turbo-aware `window.fetch` monkeypatch) for full coverage.
4. **Phase 4 — Promote to studio-engine.** Extract the DSL + AuthLadder +
   responder + modals + interceptor; add `Studio.configure` accessors; refactor
   turf-monster's `rack_attack.rb` + initializer to consume the engine DSL with
   its app-specific allowlist/numbers as config; bump engine, `bundle update`,
   re-run the turf-monster suite as the engine's harness.
5. **Phase 5 — Adopt in other apps.** mcritchie-studio + tax-studio set their own
   `config.rate_limit_*` and (optionally override) the modal partials — config +
   branded copy, no new code.

## Stress-test risks & mitigations

Verdict from the adversarial pass: **sound, with fixes.** Must-fixes folded into
the phasing above:

1. **(High) Form writes can't show the tier-1 modal.** `save_profile` /
   `unlink_google` / `set_inviter` are Turbo form / `button_to`, not
   `authedFetch`. → **Drop them from the v1 allowlist** (low-frequency); govern
   only genuine fetch paths.
2. **(High) The auth interceptor doesn't cover the real resend calls.**
   `postMagicLink` / `sendVerificationEmail` are bare fetches with their own
   error UX. → **Migrate them onto `authedFetch` + early-return before** wiring
   the tier-2 swap, or it double-handles.
3. **(High) Ladder cache keys must be swept.** Use the exact `rack::attack:`
   prefix (or extend `TestController#reseed` + e2e globalSetup) or the cross-spec
   throttle flake returns. Account for test env (`:null_store` + rack-attack
   disabled): unit-test the ladder with an injected MemoryStore.
4. **(Medium) Tier-1 double-count.** One confirm-entry gesture fans out to ~7
   governed writes. → Keep the cap ≥90/60s; consider trimming the allowlist to
   just the bursty `toggle_selection`/`pick` for v1.
5. **(Medium) Engine boundary leaks app-local knowledge** (`_card_header`,
   `modals/` path, per-app `<template x-if>`, single-root rule). → Keep partials
   at the app path for Phases 1–2; decide `_card_header` promotion before
   Phase 4.
6. **(Medium) Strict allowlist, not denylist** — so `/webhooks/stripe`, chat
   `/messages`, `prepare_entry`, and future POST routes can't be accidentally
   swept into the general cap.

## Open decisions (confirm before/while building)

- **Tier-1 threshold:** 90/60s to start, then tune from prod WARN logs?
- **Tier-1 key:** IP-only (matches every existing throttle) vs user-id for
  logged-in users (friendlier on shared NATs, but a new keying pattern).
- **Ladder scope:** confirm v1 = `magic_link` + `email_verification` only.
- **Lock the ladder numbers:** 3 / 60s / 5-min idle / **12-per-hour** ceiling
  (12 was an operator lean — confirm).
- **Interceptor coverage:** migrate all bare `fetch()` to `authedFetch`
  (explicit, lower-risk) vs a Turbo-aware `window.fetch` monkeypatch (total
  coverage, fiddlier).
- **General wait modal dismissible** (leaning yes — soft cap) vs blocking until
  the countdown ends.

## References

- `config/initializers/rack_attack.rb` — current throttles + responder.
- `app/controllers/test_controller.rb#reseed` — counter sweep (e2e).
- `app/javascript/solana_utils.js` — `authedFetch` (the interceptor chokepoint).
- `app/views/layouts/application.html.erb` — modal host + `postMagicLink`.
- `app/controllers/messages_controller.rb#posting_too_fast?` — existing
  per-user stateful limiter (the model for custom counter logic).
