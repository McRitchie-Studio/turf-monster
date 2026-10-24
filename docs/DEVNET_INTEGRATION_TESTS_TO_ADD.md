# Devnet Integration Tests (Audit Tier 3 #21)

> **ARCHIVE-ONLY PLANNING SNAPSHOT.** This captured the May 2026 devnet test
> plan. Use `docs/TEST_COVERAGE_STATUS.md` for current test coverage
> orientation. The nightly workflow below never ran on schedule and was
> deleted on 2026-10-24 (`turf-devnet-config-truth`); the devnet signal is the
> per-release `contest-rehearsal` gauntlet (`docs/SOLANA.md`).

> **Status (2026-05-23): PARTIALLY CLOSED.** `e2e/devnet-smoke.spec.js` (~890 lines) ships a comprehensive devnet smoke suite covering the Rails ↔ program contract end-to-end: vault round-trip, contest create/enter/settle, entry tokens, settlement with cosign. No CI workflow runs it (see the note above). Remaining work below is mostly edge cases.

The 2026-05-17 ecosystem audit recommended a small Playwright suite (10-15 cases) tagged `@devnet` that hits the **deployed devnet** `turf-vault` program from the turf-monster Rails layer. This catches integration drift between the program and the Rails service classes — the existing `turf-vault/tests/turf-vault.ts` covers the program against localnet but not the Rails ↔ program contract.

The nightly CI workflow this plan relied on (`.github/workflows/devnet-nightly.yml`, audit Tier 2 #13) was deleted on 2026-10-24 without ever running on schedule. This file lists the tests to write.

## Setup needed (operator, one-time)

1. **Fund a CI bot wallet on devnet** (~10 SOL via the Solana devnet faucet; use `turf-vault/docs/CURRENT_DEPLOYMENT.md` for current program identity)
2. **Generate the bot keypair** and store as base58 in 1Password
3. ~~Set GH secrets `SOLANA_BOT_KEY` and `SOLANA_RPC_URL` in the turf-monster repo~~: no workflow reads them since the nightly was deleted. The specs run by hand with the keys read from 1Password (`e2e/DEVNET_RUNBOOK.md`); use a paid Helius RPC, since public devnet rate-limits at scale.
4. ~~Set the repo variable that enabled the nightly~~ (the workflow it gated is deleted)

## Test list (target: 10-15 cases)

Each test in `e2e/devnet-*.spec.js`, tagged `@devnet` in the describe block. Reuse the bot key for all of them; reset state between tests via `Contest#reset!` rake task.

### Wallet/token plumbing
1. **Ensure user ATA** → assert a managed user's USDC ATA can be created/read without a pooled DB balance
2. **Managed-wallet USDC entry** → assert user ATA decreases and `op_rev` ATA increases by the entry fee
3. **Managed-wallet token entry** → assert an `EntryTokenAccount` is consumed and no SPL fee transfer occurs
4. **Insufficient selected currency** → asserts on-chain error surfaces as a Rails-side eligibility blocker

### Contest lifecycle (managed entry mode)
5. **create_contest (admin) → enter_contest (3 users) → settle_contest (admin + cosigner)** → winner ATAs reflect rank-based payouts
6. **Settlement with tied 1st** → tied users receive split payout (per program logic)
7. **Settlement with all entries abandoned** → no payouts, status → settled

### Contest lifecycle (Phantom entry mode)
8. **enter_contest from a Phantom-mocked wallet** → asserts on-chain ATA debit + seeds award
9. **Direct entry insufficient USDC** → on-chain error → Rails error surfaces cleanly

### Multisig boundary
10. **Settlement attempt with admin signing twice** (same key) → rejected on-chain
11. **Settlement with cosigner not in VaultState.signers[]** → rejected on-chain
12. **update_signers via 2-of-3** → succeeds; subsequent settlement uses new signer

### Reconciler against deployed
13. **Reconciler#reconcile_all** with a deliberately desynced DB → reports `entry_count_mismatch` for the affected contest
14. **Reconciler#reconcile_user** for a fully-synced bot user → no discrepancy

### IDL pinning smoke
15. **Boot Rails with EXPECTED_IDL_HASH unset** → boots cleanly (verification skipped). With matching hash set → boots cleanly. With mismatched hash set → raises `Solana::Config::IdlMismatchError`. (Run as a model test rather than e2e if simpler.)

## Implementation notes

- Use `await page.evaluate(() => window._RailsCSRFToken)` to extract the CSRF token from the rendered Rails app before POSTing to API endpoints
- For Phantom-mocked direct entry, use the existing `e2e/rpc-mock.js` extended with deployed-devnet account fetch passthroughs
- Reset DB state between tests via a beforeEach that calls a test-only `/test/reset` Rails endpoint guarded by `Rails.env.test?` + a shared secret
- Use Anchor's `await provider.connection.confirmTransaction(sig)` semantics — devnet confirms in 1-3 seconds, set test timeouts to 30s

## Why this is a separate session

The 15-test suite plus the test-helper infrastructure (Phantom mock extension, /test/reset endpoint, devnet account setup, CI secret config) is realistic ~4-6 hours of focused work. Better to do in one session than scattered.

When picking up: read this list, then `turf-vault/tests/turf-vault.ts` for reference on how the program's own tests structure the calls, then write `e2e/devnet-vault.spec.js` first (the round-trip tests are the foundation everything else builds on).
