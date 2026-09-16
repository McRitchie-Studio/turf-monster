# Stage 3 — Test Coverage Audit

> **ARCHIVE-ONLY AUDIT SNAPSHOT.** Several "zero tests" claims below were true
> in May 2026 but are no longer current. Use `docs/TEST_COVERAGE_STATUS.md` for
> the active coverage orientation.

**Date:** 2026-05-24
**Companion to:** [`SECURITY_AUDIT_2026_05_23.md`](SECURITY_AUDIT_2026_05_23.md), [`REFACTOR_AUDIT_2026_05_23.md`](REFACTOR_AUDIT_2026_05_23.md)
**Scope:** `test/**`, `e2e/**`, CI configuration, fixtures, test infrastructure

---

## Executive summary

You have **35 Rails test files (~300 minitest tests) + 42 Playwright tests + 17 nightly devnet tests**. The number is healthy but the *distribution* isn't — **11 of the highest-value files have zero tests**, and most of them touch money. Specifically:

- The Stripe + MoonPay webhooks (the controllers that receive money events) have zero controller-level tests
- `PendingTransaction` (the multisig settlement model) has zero tests
- `TransactionLog` (the ledger) has zero tests
- `Solana::Vault` (every on-chain operation goes through it) has zero unit tests
- `StripeDepositJob` + `MoonpayDepositJob` (both half of your deposit flow) have zero tests
- `WalletsController#withdraw` / `#stripe_deposit` / `#moonpay_deposit` have zero tests

The shape of the gap is consistent: green coverage on the "what users see" layer, dark zones on the "where money moves" layer. For a public-mainnet launch this is the wrong way around.

**Counts:** 5 launch blockers · 8 launch-week · 9 backlog · 5 infrastructure gaps · 7 unskippable-now tests that have been waiting on a `FakeVault` extraction that's already half-built.

---

## Verified inventory

| Layer | Files in app | Files with a test | Critical files missing tests |
|---|---|---|---|
| Models (`app/models/*.rb`) | 23 | 9 | `pending_transaction.rb`, `transaction_log.rb`, `slate_matchup.rb`, `game.rb`, `selection.rb`, others |
| Controllers (`app/controllers/**/*.rb`) | 38 | 14 | `webhooks/stripe_controller`, `webhooks/moonpay_controller`, `wallets_controller`, `solana_sessions_controller`, `admin/pending_transactions_controller`, `admin/free_entries_controller` |
| Services (`app/services/**/*.rb`) | 14 | 9 | `solana/vault.rb`, `solana/reconciler.rb`, `solana/config.rb` |
| Jobs (`app/jobs/*.rb`) | 6 | 2 | `stripe_deposit_job.rb`, `moonpay_deposit_job.rb`, `create_onchain_user_account_job.rb`, `outbound_request_sweeper_job.rb` |
| Playwright E2E | — | 42 + 17 devnet | (happy paths only; no error/dispute/race-condition scenarios) |
| Test infra | — | — | No SimpleCov, no factory_bot, empty `test/system/`, `FakeVault` duplicated inline in 2 files |

Skipped tests verified: 7 total, all blocked on RPC mocks (Vault stub).

---

## LAUNCH BLOCKERS — tests that must exist before mainnet

### BL1 — `Webhooks::StripeController#create` has zero controller-level tests
**File:** `app/controllers/webhooks/stripe_controller.rb`, no corresponding test

The only thing standing between an attacker and "mint me tokens for free" is signature verification. There's no test asserting:
- Bad signature → 400
- Test-mode event in production → 200 + ignored (the OPSEC-033 short-circuit)
- `checkout.session.completed` → `TokenPurchaseJob.perform_later` actually fires
- `charge.dispute.created` → `user.payment_risk_flag = true` AND `user.freeze_for_payment_risk!` AND `Rails.logger.error` (per B4)
- `charge.refunded` → `purchase.mark_refunded!` + freeze
- Unknown event type → 200 + logged (silent ignore, not crash)

**~6 tests, ~1 hour.** This is your highest-leverage test gap.

### BL2 — `Webhooks::MoonpayController#create` has zero tests
**File:** `app/controllers/webhooks/moonpay_controller.rb`

Same shape. HMAC signature verification → balance credit. If MoonPay is in the launch scope, this is also a launch blocker. If you're shipping launch with Stripe only + MoonPay disabled, downgrade this to LW.

**~3 tests, ~30 min** (if in scope for launch).

### BL3 — `StripeDepositJob` + `MoonpayDepositJob` are zero-coverage despite handling real USD deposits
**Files:** `app/jobs/stripe_deposit_job.rb`, `app/jobs/moonpay_deposit_job.rb`

Webhook receives the event, enqueues the job, job calls `vault.ensure_ata` → `vault.fund_user` → `vault.deposit` → `TransactionLog.record!`. If the job crashes mid-sequence (Solana RPC blip), what state is the user in? Untested. If the same webhook fires twice (Stripe retries on 5xx), does `TransactionLog`'s `stripe_session_id` unique index actually catch the dupe? Untested.

`TokenPurchaseJob` has thorough coverage of this exact pattern (9 tests, FakeVault-based, partial-failure resume verified). The same pattern should be lifted to `StripeDepositJob` and `MoonpayDepositJob`.

**~6 tests across both jobs, ~2 hours** (mostly copying/adapting the FakeVault setup from `token_purchase_job_test.rb`).

### BL4 — `PendingTransaction` (multisig settlement model) has zero tests
**File:** `app/models/pending_transaction.rb`

Every contest settlement → `PendingTransaction` row → 2-of-3 Squads cosign → broadcast. None of the model's state transitions, polymorphic target resolution, `metadata` JSONB parsing, or expiry logic is tested. Treasury bug here = inability to pay winners.

**~6-8 tests, ~2 hours.** Critical for the first time you actually grade a real-money contest.

### BL5 — `Contest#grade!` tie-payout splitting has zero tests
**File:** `app/models/contest.rb:171-223`

`#grade!` exists in `test/models/contest_test.rb` but only for the simple case. The code handles:
- 2 entries tied for 1st (split $300)
- 3+ entries spanning multiple payout tiers (e.g., 3 tied for 1st when payouts are `{1 => $300, 2 => $50, 3 => $50}` → triplet splits $400 evenly)
- Integer-cent remainder distribution when split doesn't divide evenly

None of these branches is exercised. A bug in the remainder distribution costs real money and is hard to spot on inspection — only tests reliably catch it.

**~3 tests, ~1 hour.**

---

## LAUNCH-WEEK — high severity but survivable on day one

| # | Title | Effort | Why |
|---|---|---|---|
| LW1 | Unskip the 7 skipped tests by extracting `FakeVault` to `test/support/fake_vault.rb` | 2h | `FakeVault` already exists inline in two test files (`token_purchase_job_test.rb:9`, `contests_controller_test.rb:5`). Extract + share. Then the entry-token + dev-mint + user balance tests all run. |
| LW2 | `WalletsController#withdraw` / `#stripe_deposit` / `#moonpay_deposit` tests | 1.5h | Happy path + geo gate + amount validation per action. The 3-step admin approval flow particularly needs end-to-end coverage. |
| LW3 | `Admin::PendingTransactionsController` cosign flow tests | 1.5h | The treasury UI is how settlements actually get paid out. Currently zero coverage. |
| LW4 | `Admin::FreeEntriesController#mint` + `#mint_all` tests | 1h | OPSEC-030 double-click protection (`with_lock`) is in the code but not tested. |
| LW5 | `SolanaSessionsController#verify` controller tests | 1h | Nonce reuse, wrong signature, expected_user_id mismatch (OPSEC-005). E2E covers happy path; the rejection paths don't. |
| LW6 | `ContestsController#enter` Phantom direct path + #prepare_entry/#confirm_onchain_entry | 1.5h | Phantom co-sign flow is untested at the Rails layer. PDA mismatch and TX-verify-failure paths need coverage. |
| LW7 | `TransactionLog` idempotency tests (Stripe + MoonPay session_id unique partial indexes) | 30min | Two tests, very high value, very easy. Prove the indexes actually catch retries. |
| LW8 | `B4` webhook test — Stripe `charge.dispute.created` → user frozen end-to-end | 30min | The model methods are tested (`account_freeze_test.rb`), the controller gates are tested, but the wire from webhook → freeze is not. |

---

## BACKLOG — medium severity, real but post-launch

| # | Title | Where |
|---|---|---|
| B1 | `Solana::Vault` unit tests (PDA derivation, ATA ensure, mint, enter) | docs/TESTS_TO_ADD.md Priority 1, 20 tests |
| B2 | `Solana::Reconciler` divergence-detection tests | docs/TESTS_TO_ADD.md Priority 2, 15 tests |
| B3 | `Solana::Config` IDL hash pinning / mint pinning tests | new |
| B4 | `Survivor::SimulateTournament` bracket simulation tests | new |
| B5 | `SlateMatchup.turf_score_for(rank, n)` formula tests | the central formula — surprisingly untested |
| B6 | `User#entry_token_balance` (unskippable once LW1 done) | already skipped, RPC-mock-bound |
| B7 | `Game`, `Player`, `Team`, `Selection` model behavior tests (currently fixtures-only) | new |
| B8 | CSRF-skip verification on webhook endpoints (defensive — assert future "add CSRF" PR doesn't silently break webhooks) | new |
| B9 | Concurrent-signup race test (H1) and concurrent-entry race test (H2) — both unique indexes shipped, no test proves them in motion | new |

---

## TEST INFRASTRUCTURE — gaps independent of any specific test

### I1 — No code coverage reporting
No SimpleCov, no per-file coverage minimums in CI. You can merge a PR that adds a new action with zero tests and CI doesn't notice. Add `simplecov` + a minimum threshold (start lenient, 70%) on `app/models/`, `app/controllers/webhooks/`, `app/jobs/`. ~1h.

### I2 — `FakeVault` duplicated inline, blocks all on-chain testing
`FakeVault` exists at `test/jobs/token_purchase_job_test.rb:9` AND `test/controllers/contests_controller_test.rb:5` — two slightly-divergent copies. Every test that wants to stub Solana has to redefine it. This is why 7 tests are skipped with "needs FakeVault methods" — nobody wants to maintain a third copy. Extract to `test/support/fake_vault.rb`, expand to cover the methods the skipped tests need, unskip. **~2h, unlocks ~20 follow-on tests over the next few weeks.**

### I3 — No factory_bot
All tests build records via `Model.create!(...)` or chain off fixtures. Edge cases like "user with 3 active entries in a locked onchain contest with seeds" require 30 lines of setup that's copy-pasted. Adopting `factory_bot` is a multi-hour migration but pays back fast on the controller tests that BL1-BL5 + LW2-LW8 require. **~3h setup + ongoing payoff.**

### I4 — `test/system/` directory is empty
Capybara + Selenium are configured in `test_helper.rb` but no system tests exist. The Alpine modal flows (the auth wizard, hold-to-confirm, profile completion) are tested via Playwright instead. This is a defensible split but means a quick Rails-side smoke test of a JS-driven flow is impossible. Optional — your Playwright coverage is decent.

### I5 — Playwright sequential + retries=0
`workers: 1, retries: 0` in `playwright.config.js`. 42 tests × ~30s = 22+ minute CI runs single-threaded. One flake fails the whole suite with no retry. **~15min:** `workers: 4, retries: 1` (retries only on CI). Slowest CI step gets ~4x faster, transient flakes don't block merges.

---

## E2E coverage observations (Playwright)

**Strong:** happy-path workflows. Devnet integration is rare to find at this depth in a Rails app — `devnet-smoke.spec.js` runs the full chain on real devnet nightly.

**Missing:** every error path. Zero tests for:
- Stripe card decline
- Token purchase failure mid-flow
- Geo block on entry
- Duplicate username (H1)
- Duplicate concurrent entry (H2)
- Refund handling
- Disputed-charge freeze (B4)
- "Contest full" rejection
- "No tokens" rejection

For a public launch you'll see all of these in production within the first week. At least one e2e test per failure category catches these regressing later.

---

## Recommended week-of-launch test sprint

If you can spend a focused day on tests this week, the order that maximizes safety-per-hour:

1. **BL1** — Stripe webhook tests (1h). Biggest exposure.
2. **LW1** — extract FakeVault (2h). Unlocks 7 immediate tests + makes BL3 + everything else easier.
3. **BL5** — Contest grade tie tests (1h). Real-money correctness.
4. **BL3** — Stripe + MoonPay deposit job tests (2h, FakeVault already in hand).
5. **BL4** — PendingTransaction model tests (2h).
6. **LW7** — TransactionLog idempotency (30min, very high value/effort ratio).
7. **LW8** — B4 webhook integration test (30min).
8. **I1** — Add SimpleCov + 70% threshold (1h).

That's a long but realistic day — 10 hours of focused work covering every launch-blocker test gap and the load-bearing infrastructure changes.

The remaining LW + backlog items can land in the first 2-3 weeks post-launch without being on fire.

---

## What's intentionally NOT in this audit

- Tests for the H4 service-object extraction (those files don't currently exist on the branch you're working from — they come back when your branch-cleanup task settles)
- Test files I'd previously created (`account_freeze_test.rb`, `admin/users_controller_test.rb`, `contest_entry_service_test.rb`) — same situation
- Stage 3 doesn't recommend writing tests for code that may not exist post-cleanup. Once you're on a stable branch I can do a delta pass.

---

## Stages 1-2-3 summary

You now have three written audit reports:

| Stage | Date | Outcome |
|---|---|---|
| Stage 1 — Security | 2026-05-23 | 4 launch blockers identified, all but NB1 closed in code (NB1 currently reverted per branch cleanup) |
| Stage 2 — Refactor | 2026-05-23 | NB1 surfaced as new launch blocker, H1 + H2 unique indexes shipped |
| Stage 3 — Tests | 2026-05-24 | 5 test launch blockers + 8 launch-week tests + infra gaps |

Pre-mainnet checklist that hasn't moved: **third-party Anchor audit booking** (still recommended; book Neodyme/OtterSec/Halborn now — weeks of lead time).

<!-- citation-guard: snapshot 2026-05-24 (5 citations) — dated coverage audit -->
