# Devnet E2E Test Runbook

End-to-end tests that exercise Turf Monster against real Solana devnet. These tests create real onchain contests, submit real entries, and mint real devnet USDC.

## Prerequisites

- Node.js + `npx playwright` installed (`npm install` in project root)
- Dev server running on port 3100 (`bin/dev` or `bin/rails server -p 3100`)
- Sidekiq running (`bundle exec sidekiq`) — required for `EnsureAtaJob` after user registration
- `SOLANA_BOT_KEY` env var set to Alex Bot's base58-encoded private key (same as `SOLANA_ADMIN_KEY` in `.env`)
- Alex Bot wallet funded with ~0.2 SOL + ~$20 USDC on devnet
- Mack wallet funded with ~1 SOL on devnet (USDC seeded by faucet in Test 6)

## Running In CI — the nightly lane

These 17 specs do not run in pull-request CI. `ci.yml`'s playwright job excludes
them (`--grep-invert "@devnet"`) and pins `SOLANA_RPC_URL` to a black hole so the
PR lane stays hermetic. The only lane that runs them is
`.github/workflows/devnet-nightly.yml`, at 08:00 UTC daily, plus `gh workflow run
devnet-nightly.yml`.

**Three operator switches** (Settings → Secrets and variables → Actions). Only
Mr. McRitchie can set these; an agent App token gets 403 on both endpoints:

| Setting | Kind | Value |
|---|---|---|
| `DEVNET_NIGHTLY_ENABLED` | variable | `true` |
| `SOLANA_BOT_KEY` | secret | base58 private key of a FUNDED devnet wallet |
| `SOLANA_RPC_URL` | secret | the devnet RPC endpoint to test against |

**Turning the lane off costs a red run, on purpose.** The switches are checked in
the workflow's first step, which exits 1 and names each missing one. This replaced
a job-level `if:` that made "off" complete `skipped` — grey and one second, which
is how the lane sat dead for fourteen consecutive nights (2026-08-08 to 08-21)
without anything going red. If you genuinely want the lane off, disable the
workflow in the Actions UI, which is a visible act; do not expect a quiet variable.

**A dead lane eventually reddens every PR.** `ci.yml`'s `devnet_lane_guard` job
fails a pull request once the nightly has had no *successful* run in 3 days. One
bad devnet night costs nobody a merge; three days of silence costs everybody one.
If it is red, this lane is not running and the coverage below does not exist.

**Budget the wallet for a NIGHTLY cadence.** The per-run figures below are per
run, and a nightly is ~30 of them a month: roughly **0.3 SOL and $570 devnet USDC
per month**. Both are mintable on devnet, but neither tops itself up — a wallet
that drains turns the lane red for a reason that has nothing to do with the code.
Check the balances below when the nightly starts failing at the faucet tests.

## Pre-Flight Balance Check

The tests automatically check balances and fail fast if insufficient. You can also check manually:

```bash
# SOL balance
solana balance F6f8h5yynbnkgWvU5abQx3RJxJpe8EoQmeFBuNKdKzhZ --url devnet

# USDC balance (mint: 222Dcu2RgAXE3T8A4mGSG3kQyXaNjqePx7vva1RdWBN9)
spl-token balance 222Dcu2RgAXE3T8A4mGSG3kQyXaNjqePx7vva1RdWBN9 --owner F6f8h5yynbnkgWvU5abQx3RJxJpe8EoQmeFBuNKdKzhZ --url devnet
```

### Measured Consumption Per Run

| Token | Consumption | Notes |
|-------|-------------|-------|
| SOL | ~0.01 SOL | Transaction fees (contest creation, ATA creation, entries, faucet mints) |
| USDC | ~$19 | Net cost: faucet seeds +$600 ($500 Alex, $50 Mason, $50 Mack), small contest costs -$69. Standard contest is DB-only. |

### Minimum Balances

| Token | Minimum | Why |
|-------|---------|-----|
| SOL | 0.1 SOL | Transaction fees with safety margin |
| USDC | $20 | Faucet seeds wallets before contests need USDC — only need to cover the gap |

### Topping Up

**SOL** — follow the faucet protocol in order:

1. `devnet-pow mine --target-lamports 200000000 -ud` (preferred, no rate limits)
2. https://faucet.quicknode.com/solana/devnet
3. https://faucet.solana.com
4. `solana airdrop 1 --url devnet` (last resort, often rate-limited)

**USDC** — mint via the app's faucet page at `/faucet` or use the admin CLI rake task.

## Running the Tests

```bash
# Full devnet suite (17 tests)
SOLANA_BOT_KEY=<key> npx playwright test --project=devnet

# Using the .env key directly
export SOLANA_BOT_KEY=$(grep SOLANA_ADMIN_KEY .env | cut -d= -f2) && npx playwright test --project=devnet

# Single test by name
SOLANA_BOT_KEY=<key> npx playwright test --project=devnet -g "small contest"

# Headed mode (see the browser)
SOLANA_BOT_KEY=<key> npx playwright test --project=devnet --headed
```

The `devnet` project in `playwright.config.js` filters tests by the `@devnet` tag in test names. Timeout is 180s per test.

## Test Inventory

### Part 1: Onboarding (register + seed wallets)

| # | Test Name | What It Does |
|---|-----------|-------------|
| 1 | Alex Wallet Login | Alex logs in via KeypairProvider wallet. |
| 2 | Alex Faucet | Alex claims $500 USDC from faucet. Seeds wallet for contest creation + entry fees. |
| 3 | Mason Registration | Registers Mason via magic link, completes profile. |
| 4 | Mason Faucet | Mason claims $50 USDC from faucet, verifies $50.00 balance. |
| 5 | Mack Registration | Mack connects via KeypairProvider wallet, completes profile. |
| 6 | Mack Faucet | Mack claims $50 USDC from faucet. Seeds wallet before onchain entry. |

### Part 2: Small Contest (onchain, full lifecycle)

| # | Test Name | What It Does |
|---|-----------|-------------|
| 7 | Small Contest Creation | Alex creates small (3-entry) onchain contest. |
| 8 | Mason Entry (Small) | Mason enters small contest with 6 picks. [1/3] |
| 9 | Mack Entry (Small) | Mack enters small contest via direct onchain path with 6 picks. [2/3] |
| 10 | Alex Entry (Small) | Alex enters small contest onchain with 6 picks. [3/3 — fills contest] |
| 11 | Lock Contest | Alex locks the small contest (open → locked). |
| 12 | Simulate First Game | Alex simulates the first pending game via admin action. |

### Part 3: Standard Contest (DB-only, multi-entry)

| # | Test Name | What It Does |
|---|-----------|-------------|
| 13 | Standard Contest Creation | Alex creates standard (30-entry) contest via form. DB-only (no onchain) to avoid $550 USDC bonus. |
| 14 | Mason 1st Entry (Standard) | Mason enters standard contest with 6 picks. |
| 15 | Mason 2nd Entry (Standard) | Mason re-enters with different picks (cards 6-11). Tests multi-entry + sybil check. |
| 16 | Mack 1st Entry (Standard) | Mack enters standard contest with 6 picks via standard path. |
| 17 | Mack 2nd Entry (Standard) | Mack re-enters with different picks (cards 6-11). Tests multi-entry for Web3 users. |

**Dependencies:** Tests run serially (`workers: 1`). Onboarding (1-6) seeds wallets for all later tests. Tests 8-12 depend on `sharedSmallContestUrl` (Test 7). Tests 14-17 depend on `sharedStandardContestUrl` (Test 13). Tests 4, 8, 14-15 depend on Mason's magic-link-created account (Test 3). Tests use two wallets: Alex Bot (admin) and Mack (Web3 user).

## Pre-Flight Checks (Automatic)

The `beforeAll` hook automatically:
1. Validates `SOLANA_BOT_KEY` env var is set
2. Links Alex's wallet to the bot pubkey in the dev DB (via `bin/rails runner`)
3. Clears Mack's wallet address from existing users (for clean Web3 registration)
4. Snapshots SOL and USDC balances for both Alex and Mack
5. Fails fast if Alex's balances are below minimums

The `afterAll` hook logs post-flight balances and consumption delta.

## Standard Suite Check

After running devnet tests, verify the standard suite is unaffected:

```bash
npx playwright test --project=chromium
```

The `chromium` project excludes `@devnet` tests via `grepInvert`.

## Troubleshooting

### IllegalOwner on Faucet/Entry
Error: `Transaction failed: {"InstructionError"=>[0, "IllegalOwner"]}`

Race condition between Sidekiq's `EnsureAtaJob` and the faucet's `ensure_ata`. The faucet tests include a 5-second wait to allow Sidekiq to create the token account. If this still fails:
- Verify Sidekiq is running: `ps aux | grep sidekiq`
- Restart Sidekiq: `bundle exec sidekiq`

### Insufficient SOL Balance
Error: `Attempt to debit an account but found no record of a prior credit`

Top up SOL using the faucet protocol above. Each test run uses ~0.01 SOL.

### Insufficient USDC Balance
Faucet seeds $500 for Alex and $50 per other user, so pre-existing USDC requirement is low (~$20). If still failing, mint more via `/faucet` while logged in as Alex Bot.

### RPC Timeout / Rate Limiting
Devnet RPC can be flaky. If tests fail with timeout errors:
- Retry once — devnet congestion is usually transient
- Switch RPC: set `SOLANA_RPC_URL` to a different devnet endpoint (QuickNode, Helius, etc.)
- Check devnet status: https://status.solana.com

### Tests Skipped
`No shared small contest URL from Test 7` or `No shared standard contest URL from Test 13` or `No Mason credentials from Test 3` — dependent tests skip if their prerequisite didn't run. Mason is created through the dev-only magic-link token endpoint; run the full suite, not individual tests in isolation.

### Stale Server
If tests fail on page assertions (wrong content, missing elements):
- Restart the dev server: kill port 3100, re-run
- Re-seed: `bin/rails runner e2e/seed.rb`
- Check for pending migrations: `bin/rails db:migrate`

### Faucet Claim Timeout
The faucet mints SPL tokens on devnet. If it times out at 60s:
- Check devnet RPC health
- The `solanaModal` will show an error message — check the browser console for details
