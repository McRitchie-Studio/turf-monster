# Test Coverage Status

Last reviewed: 2026-06-14.

This is the current Turf Monster test-coverage orientation. Older audit docs
such as `TESTS_TO_ADD.md` and `TEST_COVERAGE_AUDIT_2026_05_24.md` are historical
snapshots; do not use their "zero tests" claims as current truth without
checking `test/`.

## Current Shape

The test suite has materially expanded since the May audits. Current coverage
includes:

- Stripe webhook controller tests: `test/controllers/webhooks/stripe_controller_test.rb`
- PayPal webhook and token purchase tests: `test/controllers/webhooks/paypal_controller_test.rb`,
  `test/controllers/tokens_paypal_test.rb`, `test/jobs/token_purchase_job_test.rb`
- Pending transaction model/controller tests:
  `test/models/pending_transaction_test.rb`,
  `test/controllers/admin/pending_transactions_controller_test.rb`
- Entry payment state machine tests: `test/models/entry_payment_test.rb`,
  `test/models/entry_payment_concurrency_test.rb`,
  `test/services/entries/payment_settlement_test.rb`,
  `test/services/entries/managed_entry_payment_test.rb`,
  `test/controllers/contests_entry_payment_test.rb`,
  `test/jobs/entries/payment_sweep_job_test.rb`
- Transaction log idempotency tests:
  `test/models/transaction_log_test.rb`
- Contest grade tie/payout tests:
  `test/models/contest_test.rb`
- Shared Solana fake:
  `test/support/fake_vault.rb`
- Focused `Solana::Vault` boundary tests:
  `test/services/solana/vault_*_test.rb`
- On-chain entry reconciliation tests:
  `test/services/entries/onchain_reconciler_test.rb`,
  `test/jobs/entries/onchain_reconcile_job_test.rb`
- CDP ramp/offramp tests:
  `test/controllers/cdp/*_test.rb`, `test/jobs/cdp/*_test.rb`,
  `test/services/cdp/*_test.rb`

## Still-Open Gaps

Keep these as the active backlog until they are either implemented or explicitly
de-scoped.

| Area | Status |
|------|--------|
| `Solana::Reconciler` unit tests | Still no `test/services/solana/reconciler_test.rb`; current coverage is focused on `Entries::OnchainReconciler`, not the older account/contest divergence reconciler. |
| Full `Solana::Vault` omnibus test | No single `test/services/solana/vault_test.rb`; coverage exists as focused `vault_*` test files. Add missing edge cases as focused files unless a broader contract test becomes clearer. |
| MoonPay | MoonPay is not active launch infrastructure. Keep MoonPay-specific May-audit findings historical unless the provider is reintroduced. |
| Devnet nightly proof | `DEVNET_INTEGRATION_TESTS_TO_ADD.md` remains historical planning. Verify actual CI before relying on nightly devnet coverage. |
| Coverage reporting | No SimpleCov threshold is documented as active. Add only when the suite runtime and noise profile are acceptable. |

## Maintenance Rule

When adding a money-moving flow, add tests at the boundary that can lose or
mis-credit value:

1. inbound webhook or callback signature/verification;
2. durable model state transition or idempotency key;
3. background job retry/recovery behavior;
4. user-facing recovery path when provider/on-chain confirmation is delayed.

Prefer focused files over one large catch-all test. Keep historical audit docs
only as context for why an area was prioritized.
