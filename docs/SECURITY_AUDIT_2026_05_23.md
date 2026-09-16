# Pre-Mainnet Security Audit — Turf Monster Ecosystem

> **ARCHIVE-ONLY AUDIT SNAPSHOT.** This report captured May 2026 security
> findings before later auth, payment, and Solana hardening passes. Use current
> Turf docs and the newer security/audit records before acting on any item
> below.

**Date:** 2026-05-23
**Scope:** turf-monster (Rails 7.2), turf-vault (Anchor program), studio-engine + solana-studio gems, Heroku/Sidekiq/CI config
**Launch profile:** public mainnet, real Stripe, no invite gate
**Status:** Stage 1 of 3 (Security → Refactor → Tests)

---

## Executive summary

**Recommendation: NO-GO for mainnet until launch blockers are resolved.**

The codebase shows clear security discipline — strong CSRF posture, signed Stripe webhooks with re-fetch validation (OPSEC-033), filtered parameter logging, gated Sidekiq UI, rack-attack throttles on auth/webhooks/chat, idempotent token-purchase job, on-chain reconciliation, multisig treasury. Brakeman: 1 warning (Ruby EOL). The architecture is sound.

The blocking issues are not architectural — they are unfinished launch-prep items: (1) an OAuth CSRF surface that's a one-line fix, (2) a managed-wallet custody model that's acceptable for caps-on test users but not yet hardened for public mainnet, (3) refund/chargeback handling explicitly marked "TBD" in CLAUDE.md TODO that becomes exploitable on mainnet, (4) the in-flight 3-step withdrawal flow.

**Counts:** 4 launch blockers · 7 launch-week · 9 post-launch backlog · 6 needs-verification · 12 already-mitigated (false positives from automated agents). Numbers reflect deduplication and the spot-check reconciliations below.

---

## Reconciliations (what changed after spot-checking)

The four Explore agents that did the deep-dive over-reported in a few places. Corrections applied:

| Agent claim | Verdict | Why |
|---|---|---|
| "Withdrawal has no confirmation step" (CRITICAL) | Downgraded to MEDIUM (verify) | `wallets_controller.rb:99-131` creates a pending `TransactionLog`; comment at L112 references the `:approve` re-check; CLAUDE.md TODO says "admin 3-step withdrawal flow still pending". A 3-step flow exists; needs end-to-end verification but is not the "user POSTs and is drained" failure mode the agent described. |
| "Chat XSS via Turbo Streams" | Already mitigated | Confirmed by infra agent — `<%= message.body %>` autoescapes; stream key is `[contest, :messages]` server-computed. |
| "Settlement TX blob tampering" | Mitigated by `TxVerifier#verify!` | Verifier re-fetches the TX from chain; attacker would need cosigner to sign the mutated blob unknowingly. Hardening still recommended (hash settlements array). |
| "RPC retries double-execute" | Largely mitigated by Anchor PDA init constraint | Most state-changing instructions use `init` on a PDA derived from a sequence, so a second submission lands as "already initialized". Worth confirming for `mint_entry_token`. |
| "Solana nonce 5-min expiry" | Already mitigated | Delete-before-verify + session-bound. |
| "Email-change token reuse" | Already mitigated | Token email-bound; mismatch fails. |
| "Admin Reset has no confirmation" | Mostly UX | Rails CSRF protects; add a confirm dialog but not a launch issue. |

---

## LAUNCH BLOCKERS (must fix before mainnet)

### B1 — OmniAuth allows GET on request phase (silent OAuth login CSRF)
**File:** `config/initializers/omniauth.rb:9` — `OmniAuth.config.allowed_request_methods = [:post, :get]`

Allowing GET to `/auth/google_oauth2` permits silent sign-in from any link. If the victim is logged into Google, an attacker-controlled page (or stored XSS, even in a sibling app sharing the `.mcritchie.studio` cookie domain — see B3) can trigger sign-in invisibly. The `omniauth-rails_csrf_protection` gem expects POST-only — the explicit `:get` opt-in defeats it.

**Fix (one line):** `OmniAuth.config.allowed_request_methods = [:post]`. All `button_to "Sign in with Google"` calls already use POST.

**Verify after fix:** confirm `omniauth-rails_csrf_protection` is doing its job — `/auth/google_oauth2` should 405 on GET.

---

### B2 — `ENABLE_TEST_SCAFFOLDING` deploy guardrail missing
**Files:** `app/models/stripe_purchase.rb:16-23`, `app/models/contest.rb:104-108`, `app/services/app_flags.rb:12-14`

The flag unlocks a $1 micro contest tier and a $5/3-token bundle. Default is off, but there's no boot-time enforcement that it stays off in production. One stray Heroku config var → an attacker can buy unlimited tokens at $1.67 each and enter $1 contests indefinitely. This is the kind of thing that ships by mistake the day of launch.

**Fix:** in an initializer, `raise` (or `Rails.logger.error` + Sentry alert) on boot if `Rails.env.production? && AppFlags.test_scaffolding_enabled?`. Add to your pre-launch checklist: confirm `heroku config:get ENABLE_TEST_SCAFFOLDING --app turf-monster` returns blank.

---

### B3 — Cookie domain scoped to `.mcritchie.studio`
**File:** session store config (currently scopes session cookie to `.mcritchie.studio` per infra agent's "Positive" notes — see below)

This means every sibling app under `mcritchie-studio` shares the cookie surface. A stored XSS or open redirect anywhere on `*.mcritchie.studio` lets an attacker exfiltrate the turf-monster session cookie OR plant a fixated cookie (combine with B1 for OAuth-silent fixation). For a mainnet money app the blast radius is unacceptable.

**Fix:** scope the session cookie to `turf.mcritchie.studio` specifically. Cross-app SSO (`/sso_continue`) is a separate signed-payload flow per CLAUDE.md and doesn't depend on a shared cookie.

**Confirm first:** I read this from the infra agent's report but didn't re-read your `config/initializers/session_store.rb` — verify before changing.

---

### B4 — Refund / chargeback path mints on-chain tokens with no clawback
**Files:** `app/controllers/webhooks/stripe_controller.rb:51-56,110-133`, CLAUDE.md TODO ("Refund/expiry rules + chargeback handling still TBD")

On mainnet:
1. User buys 3 entry tokens for $49, tokens minted on-chain (irreversible).
2. User enters contest(s), potentially wins payouts.
3. User initiates chargeback weeks later. Webhook flags `payment_risk_flag = true` but tokens remain on-chain and any payout has already happened.
4. Stripe refunds the $49. Attacker has stolen the tokens + any winnings — net positive even with the chargeback.

This is the highest-EV economic attack on the system right now. At minimum: on `charge.refunded` / `charge.dispute.created`, freeze the user's account (block entry submission, withdraw, token use), notify ops, and require manual review before the user can act. Even better: hold tokens behind a 24-72hr "settled" window after the underlying Stripe charge passes dispute risk.

**Recommend:** open this as a P0 before launch; the "operator subsidizes prize pools as needed" v1 stance compounds the loss (the operator eats both the chargeback AND the payout).

---

## LAUNCH-WEEK (fix within first 7 days)

### LW1 — Email verification doesn't gate money actions
Manual signup logs the user in with `email_verified_at = NULL`. They can deposit, buy tokens, enter contests immediately. Two problems: (a) account squatting (attacker claims `victim@example.com` before victim signs up), (b) no email = no support recovery path. Add `before_action :require_verified_email` to deposit / token purchase / entry submission.

### LW2 — Session token not rotated on email/password login
Login at `sessions#create` does not call the existing `regenerate_session_token!` (auth agent #5). Rails rotates the *cookie* on login, but your OPSEC-045 `session_token` binding is read from the user record. An attacker who pre-captured a `session_token` and fixated a session ID can ride a successful login. One-line fix: call the regenerate inside `sessions#create` after authentication succeeds, and inside `omniauth_callbacks_controller#create`.

### LW3 — IDL hash verification only at boot
`Solana::Config#verify_idl!` runs in `after_initialize`. On Heroku, dynos restart frequently — usually fine — but on a long-lived dyno a tampered IDL or a redeployed program at the same address goes undetected until restart. Either re-verify on each `Vault` instantiation (cheap; hash is local) or run a 5-minute heartbeat job that re-fetches IDL hash and alerts on mismatch.

### LW4 — `EXPECTED_IDL_HASH` defaults to empty string
`app/services/solana/config.rb:51` — `ENV.fetch("EXPECTED_IDL_HASH", "")`. If the env var is missing in prod, verification silently no-ops. Change to `ENV.fetch("EXPECTED_IDL_HASH")` (raise on missing) for production.

### LW5 — Token consumption race: parallel POSTs could waste a token
`contests_controller.rb:318-355` — read-token / on-chain consume / DB confirm sequence is not wrapped in a user row lock. Anchor's PDA init prevents the on-chain double-consume, but two parallel HTTP entries could each call `next_unconsumed_entry_token` for the same token, one succeeds on-chain, the other gets an error mid-flight and the DB ends up with an orphan cart entry. Wrap in `current_user.with_lock do ... end` like `payout_entry`.

### LW6 — Bot wallet (`SOLANA_ADMIN_KEY`) lives in Heroku env vars
Per `app/services/solana/keypair.rb:22-28`. Anyone with Heroku admin can extract it. As a 1-of-3 multisig signer it's not catastrophic alone, but combined with social-engineering one cosigner it drains the vault. For mainnet, either (a) move the bot key to AWS Secrets Manager / HSM with audit logs, or (b) accept the risk and document it explicitly in your runbook — your cosigners then know to never blind-sign.

### LW7 — Missing HSTS + permissive CSP
Infra agent: `config.force_ssl = true` is set but no `ssl_options` with `hsts: { preload: true, includeSubdomains: true }`; CSP allows `unsafe-inline` and `unsafe-eval` on script-src (Alpine's constraint). First-visit MITM downgrade is possible. Add HSTS now; CSP nonce migration can wait but un-pin `unsafe-eval` if Alpine doesn't strictly need it.

---

## POST-LAUNCH BACKLOG

| # | Issue | Severity | Where |
|---|---|---|---|
| PL1 | No password reset flow | Medium | gap, feature work |
| PL2 | Login error message reveals registered emails when combined with per-email rate limit | Medium | `sessions_controller.rb` (engine) |
| PL3 | Settlement TX semantic re-verification (`TxVerifier` checks signature but Rails computes winners) | Medium | `Contest#settle_onchain!`, `Solana::TxVerifier` |
| PL4 | `PendingTransaction` integrity hash of `settlements` array | Medium | `app/models/pending_transaction.rb` |
| PL5 | Active Storage upload validators (content_type, byte_size) for `User#avatar`, `Contest#contest_image` | Medium | `app/models/user.rb`, `contest.rb` |
| PL6 | Audit log for role changes | Low | `User#role=` callback |
| PL7 | Email-change notification only to old email (not new) | Low | `accounts_controller.rb:53-68` |
| PL8 | Admin Reset confirmation dialog | Low | UX |
| PL9 | Ruby 3.1 EOL (Brakeman) — upgrade to 3.3 | Low | `.ruby-version`, `Dockerfile` |

---

## NEEDS VERIFICATION (I couldn't confirm one way or the other in this pass)

| # | Claim | Where to check |
|---|---|---|
| V1 | The 3-step withdraw flow (request → admin approve → admin mark fiat-sent) re-checks balance, ownership, and doesn't allow self-approval | `wallets_controller.rb#withdraw` + the admin `:approve` action + `app/controllers/admin/transactions_controller.rb#complete` |
| V2 | `omniauth-rails_csrf_protection` actually rejects GET to `/auth/google_oauth2` after fixing B1 | manual `curl -i` test post-fix |
| V3 | Chat partial `app/views/messages/_message.html.erb` uses `<%= %>` not `<%== %>` | open the file |
| V4 | OAuth popup `targetOrigin` is `window.location.origin`, not `"*"` | `app/views/omniauth_callbacks/popup_close.html.erb` |
| V5 | Session cookie really is `.mcritchie.studio`-scoped | `config/initializers/session_store.rb` |
| V6 | `solana:reencrypt_managed_wallets` rake task has run on production (legacy ciphertext exists?) | `heroku run bin/rails solana:reencrypt_managed_wallets:check` or equivalent |

---

## MUST DO BEFORE MAINNET (not code — engagements)

1. **Third-party Anchor audit of turf-vault.** I cannot replace this. The custodial agent flagged 6 areas needing specialist review (PDA derivation with user-controlled `entry_num`, settlement remaining_accounts pattern, `update_signers` time-lock absence, `force_close_vault` authority, arithmetic overflow in payout caps, CPI ownership checks). Quotes from Neodyme, OtterSec, or Halborn typically run $15-50k for ~500 lines of Rust. Book it now — turnaround is weeks, not days.

2. **Insurance / treasury cap.** Decide and document the max USDC you're comfortable holding in the vault PDA at any time. Beyond that cap, sweep to cold storage. A bug or key compromise should have a bounded blast radius.

3. **Incident runbook.** Document: what happens if (a) `SOLANA_ADMIN_KEY` leaks, (b) `MANAGED_WALLET_ENCRYPTION_KEY` leaks, (c) Heroku is compromised, (d) a vault drain is detected. Who pauses contests, who rotates keys, who notifies users.

4. **Confirm prod env vars match `.env.example`** — CLAUDE.md lists what's set on Heroku but doesn't include `SOLANA_ADMIN_KEY`, `MOONPAY_*`, `RECONCILER_ALERT_WEBHOOK`, `STRIPE_API_KEY` (for `stripe listen` dev). Run `heroku config --app turf-monster` and diff against `.env.example`.

---

## POSITIVE NOTES (defense-in-depth that's already working)

- ✅ Brakeman: 1 warning (Ruby EOL), zero exploit-class findings.
- ✅ Strong params throughout. No `permit!`, no raw SQL, no `find_by_sql`, no string-interpolated `where()`.
- ✅ Stripe webhook: signature verified + re-fetch validator (OPSEC-033) + `payment_status`/`livemode`/`amount`/`kind` cross-checks.
- ✅ MoonPay webhook: HMAC + `ActiveSupport::SecurityUtils.secure_compare`.
- ✅ rack-attack throttles login, Solana auth, webhooks, faucet, email verification, chat.
- ✅ Sidekiq UI gated by `SidekiqAdminMiddleware`.
- ✅ `filter_parameter_logging.rb` covers signature, serialized_tx, private_key, nonce, recovery_phrase. `OutboundRequestLogger` deep-redacts.
- ✅ Sentry `send_default_pii = false`.
- ✅ `TransactionLog` has a unique index on `stripe_session_id` — DB-level idempotency catches re-delivered webhooks even if the app-level check races.
- ✅ `Contest#grade!` is wrapped in `with_lock` + `already settled` check — admin double-click can't double-pay.
- ✅ `Entry#confirm!` uses row-level `with_lock` — protects entry-fee deduction.
- ✅ On-chain `Solana::Reconciler` runs every 15min and logs (does not auto-correct — correct design).
- ✅ Solana nonce: delete-before-verify, session-bound, host-bound (OPSEC-018).
- ✅ Webhook controllers correctly skip CSRF (third parties can't have CSRF tokens) and depend on signature verification, which is timing-safe.
- ✅ Cookies: `secure: true`, `httponly: true`, `same_site: :lax`.
- ✅ Docker non-root user, multi-stage build, no secrets baked in.
- ✅ Stripe production credentials are validated at boot (production fails to start with test keys).

---

## Suggested triage order

1. **Today/tomorrow:** B1 (one line), B2 (one initializer), V2/V3/V4/V5 (5-minute file reads).
2. **This week:** B3, B4 (design decision then code), LW2, LW4, LW5.
3. **Next week:** LW1, LW3, LW6, LW7.
4. **In parallel:** book the Anchor audit and write the incident runbook.

Reply with which of these you want me to:
- Verify (V1–V6)
- Fix in-session (B1/B2/LW2/LW4/LW5 are small)
- Defer to the refactor stage (some PL items overlap)

Stage 2 (refactor / scalability) is blocked on your triage.

<!-- citation-guard: snapshot 2026-05-23 (10 citations) — dated security audit -->
