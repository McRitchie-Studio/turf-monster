# Solana Integration

"DeFi mullet" — Web2 UX front, Solana settlement back. **Read paths** rescue-and-log (balance/seeds display falls back to 0 on RPC error). **Money-mutating paths** (create_contest, enter, settle) are TX-first — the on-chain transaction confirms *before* the DB row is written/promoted — and fail closed: `Solana::Vault.ensure_program_id_live!` raises if `PROGRAM_ID` isn't on the RPC, and `Solana::Config.verify_idl!` refuses to boot/precompile in prod on IDL drift. The app does not transact against a missing or IDL-mismatched program.

## Architecture: self-custody (v0.16+)

There is **no pooled server vault balance**. USDC and USDT live in each user's **own ATA**:
- **Managed (web2) wallets** — Rails holds the user's Ed25519 secret, encrypted at rest, and server-signs on their behalf. Funds still sit in the user's ATA.
- **Phantom (web3) wallets** — true self-custody; the user signs in the browser.

Money movement is decoupled into two PDA families (both owned/authority = the `VaultState` PDA, neither is a pooled "vault balance"):
- **Entry fees** → per-currency **operator-revenue** ATA `[b"op_rev", mint]`. `enter_contest` SPL-transfers the fee from the user ATA into here.
- **Prize pools** → per-contest **prize-pool** ATA `[b"prize_pool", contest_id]`, pre-funded by the contest creator at `create_contest`. Settlement pays winners out of this.

The two are **decoupled**: entry fees are operator revenue and do **not** count toward the settlement cap. The only settlement constraint is `sum(payouts) <= contest.prize_pool`.

## Services (`app/services/solana/`)

Local (turf-monster) classes:
- `Solana::Config` — program ID, RPC URLs (server **and** browser — see below), mints, network, signer set, IDL pinning (`verify_idl!`), plus `redact_rpc_url` (the shared log/terminal redactor for endpoints that carry a provider key).
  - **`Solana::Config.client` is the only sanctioned way to build a server-side RPC client.** A bare `Solana::Client.new` lets the *gem* pick the endpoint — it falls back to `ENV.fetch("SOLANA_RPC_URL", <public devnet>)`, which **fails open** where `Solana::Config::RPC_URL` fails closed (OPSEC-012), and it sits outside the public/credentialed split and `redact_rpc_url`. A caller that genuinely needs its own endpoint passes `rpc_url:` sourced from `Solana::Config`. Enforced against the source tree by `test/services/solana/client_routed_through_config_test.rb` (the sibling of PR 390's `.erb` / `app/javascript` ban, which is blind to Ruby).
- `Solana::Keypair` — Ed25519 keygen, sign, base58, and encrypt/decrypt of managed-wallet secrets via a 256-bit key derived from the **`MANAGED_WALLET_ENCRYPTION_KEY`** env var (OPSEC-015; `secret_key_base[0,32]` is a legacy fallback only). `#inspect`/`#to_s` are redacted (OPSEC-021).
- `Solana::Vault` — high-level builders + senders for the current TurfVault instruction surface (see table below). Managed-wallet paths sign server-side; Phantom paths build partial transactions for browser/user signatures plus server cosign where required. `sync_balance` surfaces the user's USDC ATA balance (back-compat `:balance` key) + decodes `seeds` from the `UserAccount` PDA; `fetch_wallet_balances` reads USDC/USDT ATAs; `ensure_program_id_live!` guards stale env.
- `Solana::TxVerifier` — fetches a confirmed TX and asserts it touches `PROGRAM_ID` with the expected Anchor discriminator + signer + writable PDA (OPSEC-010). Defeats "submit any successful signature."
- `Solana::ErrorInterpreter` — maps on-chain error codes into the JS eligibility-blocker `{reason, mode, data}` shape. Friendly mappings include the v0.15.1 username codes `6020`/`6021`/`6022` (UsernameReserved / UsernameInvalidChars / UsernameTooShort) and `6027` EntryFeeNotSet (entering with a currency the contest's `entry_fee_by_currency` never funded); `app/javascript/solana_errors.js` (`parseSolanaError`) mirrors the same codes client-side.
- `Solana::Reconciler` — compares **on-chain contest state** (entry counts, slot-0 `entry_fees`) and per-user on-chain account presence against the DB; writes discrepancies to `ErrorLog` only. **No** Slack/Discord webhook. The scheduled cron was **removed 2026-05-19 (OPSEC-040)** — run ad-hoc via the rake tasks below.
- `Solana::ClientLogger` — prepended onto the RPC client to write `OutboundRequest` audit rows.

RPC + serialization primitives come from the **`solana-studio` gem** (`~> 0.4.7`), not local: `Solana::Client` (JSON-RPC over Net::HTTP, retry/blockhash logic), `Solana::Borsh`, `Solana::Transaction` (builder, `find_pda`, `anchor_discriminator`, partial signing), `Solana::SplToken`.

## Anchor Program (`turf-vault/`)

Separate project at `/Users/alex/projects/turf-vault/`. Current deployment identity is canonical in `turf-vault/docs/CURRENT_DEPLOYMENT.md`; do not copy stale program IDs or signer keys from old launch notes.

- Devnet program ID: `EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ`
- Mainnet program ID: `DaFv83yokwTz8msP9CzJ13eazSGk15NuUTxjkfzJzxMM`
- Superseded/orphaned devnet programs include `Dx8uGU5w7B9NytDSsW4kseGZuqdVVRq1KY1mGXN2GaCT` and `7Hy8GmJWPMdt6bx3VG4BLFnpNX9TBwkPt87W6bkHgr2J`; never use them for live verification.
- `VaultState` PDA `[b"vault"]` is a **zero-copy singleton** (~1515 bytes) holding the signer set, threshold, `paused` flag, the pinned `payout_mint` (USDC), the pinned `treasury_authority` (Squads vault PDA), and the 16-slot `accepted_currencies` registry. It holds **no pooled token balance**. Rails decodes it via hardcoded byte offsets in `vault.rb#read_vault_state`.
- IDL: committed at `config/turf_vault.idl.json` for devnet and `config/turf_vault.mainnet.idl.json` for mainnet, SHA256-pinned via `EXPECTED_IDL_HASH` (`Solana::Config.verify_idl!`). Current source-tree hashes: devnet `f11446facec1043cb15b169929aaff3da9e955e05f3c462e86c7b584706246e9`; mainnet `b9b522635894a42f5434f1faa1cd126d146f3042ae2c233acd1dd76a300f7152`. Live Heroku truth is the configured `EXPECTED_IDL_HASH` allow-list; a committed IDL can be staged before a mainnet upgrade is accepted.
- USDC Mint (devnet test): `222Dcu2RgAXE3T8A4mGSG3kQyXaNjqePx7vva1RdWBN9` — registry **slot 0** (= `payout_mint`, the immutable settlement currency).
- USDT Mint (devnet test): `9mxkN8KaVA8FFgDE2LEsn2UbYLPG8Xg9bf4V9MYYi8Ne` — registry **slot 1**. (Mainnet builds pin Circle USDC `EPjFWdd5…Dt1v` + Tether USDT `Es9vMFr…wNYB`.) All amounts are `u64` at 6 decimals (1 USDC = 1_000_000).

### Instructions (22)

| Instruction | Auth | What it does |
|---|---|---|
| `initialize` | `INIT_AUTHORITY` (mainnet); any signer on dev | One-time singleton setup: create `VaultState`, pin `payout_mint`=USDC + `treasury_authority`, register USDC (slot 0) + USDT (slot 1), init their `op_rev` ATAs, lock in `signers[3]` + `threshold`. |
| `update_signers` | **2-of-3** | Rotate vault signer pubkeys in place; threshold remains pinned at 2; signer-continuity guard prevents bricking governance. |
| `register_currency` | **2-of-3** | Add a mint to the next free `accepted_currencies` slot + init its `op_rev` ATA. Rejects duplicates / full registry. |
| `deactivate_currency` | **2-of-3** | Flip a slot `active=0` (slot/`op_rev` never reclaimed → `currency_idx` stable). |
| `pause` | **2-of-3** | Set `paused=1` → blocks **only** `enter_contest{,_with_token}` (everything else stays callable). |
| `unpause` | **2-of-3** | Set `paused=0`. No auto-unpause. |
| `create_user_account` | permissionless payer | Allocate `UserAccount` `[b"user", wallet]` with an on-chain-validated `username` (the wallet is *not* a signer → operator-funded onboarding). |
| `set_username` | **user-signed** | Overwrite the caller's username (re-runs `validate_username`; uniqueness/homoglyph checks stay off-chain). |
| `admin_create_user_account` | permissionless payer + **1-of-3** | Create a user account with a reserved-prefix waiver for operator-owned names; charset and minimum length still enforced. |
| `admin_set_username` | **user-signed** + **1-of-3** | Set a reserved-prefix username with owner consent plus vault-signer authorization; charset and minimum length still enforced. |
| `create_season` | **1-of-3** | Create `Season` `[b"season", id]` with an immutable per-entry `seed_schedule [u64;5]`. |
| `create_contest` | **1-of-3** payer + **creator** | Init `Contest` + `prize_pool` ATA and SPL-transfer the creator's USDC into the pool. `sum(payout_amounts) == prize_pool`. Operator-funded contests use the admin for both slots. |
| `set_contest_lock_time` | **1-of-3** | Set/clear `lock_timestamp` (v0.17 derived lock; `0`=no lock). Rejected once settled/cancelled or past `conclusion_timestamp`. |
| `set_contest_conclusion_time` | **1-of-3** | Set/clear `conclusion_timestamp` (v0.18); once chain time passes it, the lock time is final. |
| `enter_contest` | **user-signed** + **1-of-3** payer | Paid entry: SPL-transfer fee user-ATA → `op_rev` ATA, init `ContestEntry`, award seeds, bump `entry_fees`/`current_entries`. One path serves Phantom (user signs) + managed (server signs both slots). |
| `enter_contest_with_token` | **user-signed** + **1-of-3** payer | Token-funded entry: consume an `EntryTokenAccount` (no SPL transfer), award seeds. `currency_idx = 255` sentinel; does **not** bump `entry_fees` (intentional v1 gap). |
| `mint_entry_token` | **1-of-3** | Mint a pre-purchased free-entry voucher `[b"entry_token", sha256(source_ref)]` (`source`: operator/Stripe/MoonPay). Not pause-gated. |
| `grant_seeds` | **1-of-3** | Credit quest/referral seeds to a user's `UserAccount`; idempotent per `(wallet, kind, invitee)` guard PDA. |
| `settle_contest` | **2-of-3** | Grade: per-winner SPL-transfer `prize_pool` → winner ATA (PDA-signed), update entry/user stats. `remaining_accounts` = triples `[user_account, entry, winner_ata]`. Cap = `sum(payouts) <= prize_pool`. |
| `cancel_contest` | **2-of-3** | Refund the full live `prize_pool` balance → creator ATA; status→Cancelled (entry fees stay operator revenue). |
| `close_contest` | **1-of-3** | Reclaim rent on a Settled/Cancelled contest: dust-sweep `prize_pool`→`op_rev` USDC, close both PDAs. |
| `sweep_operator_revenue` | **2-of-3** | Drain an `op_rev` ATA → treasury ATA (enforces `treasury_ata.owner == treasury_authority`). |

### Accounts / PDAs

| Account | Seeds | Purpose |
|---|---|---|
| `VaultState` | `[b"vault"]` (singleton) | Zero-copy: `signers[3]`, `threshold`, `paused`, `payout_mint`, `treasury_authority`, `accepted_currencies[16]`. No funds. |
| `AcceptedCurrency` | inline (1 of 16 slots in `VaultState`) | `{mint, op_rev_ata, kind, active}`. Slot 0=USDC, 1=USDT. |
| `UserAccount` | `[b"user", wallet]` | 133 B. `username` (on-chain master), `seeds`, stat counters (`entries`/`wins`/`cashes`/`total_won`). **No balance fields** (v0.16). |
| `Contest` | `[b"contest", contest_id]` (`contest_id = SHA256(Rails slug)`) | `prize_pool`, `entry_fee_by_currency[16]`, `entry_fees[16]` (revenue tally), `max_entries`/`current_entries`, `status`, `payout_amounts`, `lock_timestamp` (v0.17), `conclusion_timestamp` (v0.18). INIT_SPACE unchanged v0.16→v0.18 (timestamps carved from `_reserved`). |
| `ContestEntry` | `[b"entry", contest_id, wallet, entry_num u32 LE]` | `status` (Active→Won/Lost), `rank`, `payout`, `currency_idx` (`255` = token-funded). Up to 3 per user (Rails cap). |
| `EntryTokenAccount` | `[b"entry_token", sha256(source_ref)]` | Pre-purchased free-entry voucher. `source` (0=operator/1=Stripe/2=MoonPay), `source_ref_hash`, `consumed`. Discover via `getProgramAccounts` by owner. |
| `Season` | `[b"season", season_id u32 LE]` | Immutable `seed_schedule [u64;5]` (entry N → `seed_schedule[min(N,4)]`). |
| `prize_pool` ATA | `[b"prize_pool", contest_id]` (authority = `VaultState`) | Per-contest USDC prize pool; funded at create, paid at settle, refunded at cancel. |
| `op_rev` ATA | `[b"op_rev", mint]` (authority = `VaultState`) | Per-currency operator revenue; entry fees land here, swept to treasury. |

### Two-level multisig auth

- **1-of-3 vault signer** (`vault_state.is_signer(key)`) — routine ops: `create_contest` (payer), `set_contest_lock_time`, `set_contest_conclusion_time`, `close_contest`, `mint_entry_token`, `create_season`, `grant_seeds`, admin username reserved-prefix waivers, and the **payer** slot of `enter_contest{,_with_token}`. Driven by the always-online Alex Bot server key.
- **2-of-3 multisig** (`vault_state.validate_multisig(admin, cosigner)`, distinct signers) — treasury/governance ops: `settle_contest`, `cancel_contest`, `register_currency`, `deactivate_currency`, `sweep_operator_revenue`, `pause`, `unpause`, `update_signers`.
- **User signature** required for `set_username` and the **user** slot of `enter_contest{,_with_token}` (the user must consent to spending from / consuming their own funds — OPSEC-004).
- `create_user_account` is permissionless (payer only); `initialize` is gated to `INIT_AUTHORITY` on mainnet builds.

Signers (`VaultState.signers`, threshold 2):
- Alex Bot (server) — `8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd`
- Alex (human Phantom, = `INIT_AUTHORITY`) — `7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr`
- Mason — `CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR`

### Program Upgrades — Squads multisig (OPSEC-002, 2026-05-19+)

**`anchor deploy` no longer works.** The program upgrade authority is a Squads V4 2-of-3 multisig vault (`BW13kgfiG2koFn3WRkte21NW9TFygsD1ge2fNJdjH6kC`) — distinct from `VaultState`'s in-program multisig — not a single keypair. Every upgrade goes through the Squad. Running `anchor deploy` will fail because the Solana CLI signs as a single keypair that is no longer the upgrade authority.

Use `turf-vault/scripts/squad-upgrade.js` — it builds a buffer, sets the buffer authority to the Squad vault, then proposes + approves the upgrade tx through the Squad. Treat `turf-vault/docs/CURRENT_DEPLOYMENT.md` as the canonical program identity record; use the McRitchie Studio credential inventory for current 1Password item names instead of copying key refs into this app doc.

**Post-deploy IDL re-pin (mandatory)**: After every Squad upgrade, turf-monster MUST re-pin `EXPECTED_IDL_HASH` from the **freshly built** IDL — NOT `anchor idl fetch`. Squad upgrades run only the BPF `upgrade` instruction; they do NOT update the on-chain IDL account. `anchor idl fetch` therefore returns the stale pre-upgrade IDL.

```bash
# After deploying turf-vault:
cp /Users/alex/projects/turf-vault/target/idl/turf_vault.json \
   /Users/alex/projects/turf-monster/config/turf_vault.idl.json
cd /Users/alex/projects/turf-monster
shasum -a 256 config/turf_vault.idl.json   # → this is the new EXPECTED_IDL_HASH

# Set EXPECTED_IDL_HASH on Heroku BEFORE git push (assets:precompile runs verify_idl!):
heroku config:set EXPECTED_IDL_HASH=<sha> -a turf-monster-mainnet

# Then commit + deploy
git add config/turf_vault.idl.json
git commit -m "Re-pin IDL after turf-vault vX.Y.Z deploy"
bin/deploy
```

`Solana::Config.verify_idl!` will refuse to boot — and to precompile assets — in production when the file's SHA256 ≠ `EXPECTED_IDL_HASH`. Running prod against a drifted IDL silently corrupts every Borsh decode.

**Also refresh the `/contract` page**: if the deploy changed the instruction set, byte sizes, auth roles, or any Rails call site, update the hand-maintained data in `app/views/contract/show.html.erb` (the public `/contract` transparency page; admin sections include the web2/web3 caller map). Its version pill + network auto-track the re-pinned IDL (`Solana::Config.idl_version` / `NETWORK`), but the per-instruction byte/caller data does not. Re-measure bytes with a debug-info rebuild (`CARGO_PROFILE_RELEASE_DEBUG=2 … cargo-build-sbf` → `llvm-objdump --syms | rustfilt`, dedup by address, bucket by instruction module).

### Multisig Settlement Flow
1. `Contest#grade!` scores entries and calls `settle_onchain!`
2. `settle_onchain!` calls `Vault#build_settle_contest` → creates a `PendingTransaction` with the partially-signed TX (2-of-3)
3. Admin visits `/admin/pending_transactions` (Treasury page)
4. Clicks "Co-sign" → Phantom signs as the second signer → TX submitted to Solana
5. On-chain: per-winner SPL transfer `prize_pool` PDA → winner USDC ATA (PDA-signed by `VaultState` seeds); contest status → Settled

> ⚠️ `grade!` marks the DB `settled` (writes `payout_cents` + TransactionLog credits) even if the on-chain settle PT is never cosigned — the sweeper deliberately skips treasury PTs, so no alert fires on an un-cosigned settle. Cosign promptly or winners stay unpaid on-chain.

## Navbar Balance

`display_balance` helper shows the user's on-chain **USDC + USDT combined** (operator request 2026-06-10 — the pill is total spendable dollars; the `/account` tiles stay per-currency) for **all** wallet types — there is no DB-balance tracking in v0.16. Cache-first + non-blocking: it sums the cached `usdc_cache_key` + `usdt_cache_key` values (60s TTL), returns `nil` when both are cold ("loading" — the pill is hidden until the client hydrate paints it), and never issues an RPC on the render path. The `/admin/usdc_balance` JSON endpoint's `balance` field is the same combined sum (per-currency `usdc`/`usdt`/`seeds` ride alongside); it is the one `AdminController` action excluded from `require_admin` (self-only; audit #27). The blocking reads live in `ApplicationController#fetch_navbar_hydrate` → `Vault#fetch_wallet_balances` + `sync_balance`, fanned out in parallel threads, which also warms the caches.

**Balance refresh system**: **`refreshSession()`** (→ `/account/session_refresh`) is THE single page-load hydrate — the layout's `hydrateNavbar()` calls it on every load, and the gear sidebar calls it on demand. It updates the combined balance slot (`[data-balance-display]` for the amount, `[data-free-entry-label]` for the "✨ Free Entry" stand-in at $0-with-tokens, picked by `applyBalanceSlotRule`), the ✨ badge (`updateNavTokens`), the seeds bar, `$store.session.usdcCents`/`usdtCents`/`tokensAvailable`, and the wallet tiles. The token count follows the wallet that can sign in the active session: managed address for web2, Phantom address for web3. Entry success does not call `refreshSession()`; both board success branches lower the store immediately through `mirrorTokenSpend()` when the server returns `token_consumed`, while server-side cache invalidation makes the next hydrate authoritative. `refreshBalance()` (→ `/admin/usdc_balance`) is the lighter balance+seeds-only sibling; `refreshBalanceDelayed(ms)` waits (default 10s) then calls it — spins the navbar refresh icon during the wait. **Wallet tiles**: both hydrate paths call `updateWalletTiles(data)` — any page subscribes a readout by tagging an element `data-wallet-tile="usdc|usdt|sol|tokens"` (the `/account` Identities row; its Refresh Wallet button is the `walletRefresh` factory in `shared/_alpine_factories.html.erb`). Null fields (flaked RPC) never overwrite a prior render.

## Wallet Types

- **Managed (web2)**: Server generates an Ed25519 keypair and stores the secret encrypted (via `MANAGED_WALLET_ENCRYPTION_KEY`), signing on behalf of the user. USDC still lives in the user's own ATA.
- **Phantom (web3)**: User connects the Phantom browser extension (or any Wallet-Standard wallet) and signs transactions directly.

Client signing paths run a network-intent guard before wallet requests. The guard compares Rails env to the app's configured Solana cluster (`production` → Mainnet, everything else → Devnet); unknown or mismatched cluster state opens the `network-guard` modal and requires an explicit checkbox acknowledgement before signing. Phantom does not expose its selected wallet network to websites, so this is an app-cluster/environment guard rather than a browser-readable Phantom-network assertion.

## Hard Escrow Contest Creation (Phantom-driven, 2026-05-18+)

Contest creation transfers the prize-pool USDC from the creator's Phantom wallet into the **per-contest `prize_pool` PDA** `[b"prize_pool", contest_id]` (authority = `VaultState`) — real hard escrow, not just a number on a PDA, and **not** a shared vault balance. Dual-signer: the admin bot pays SOL rent, the creator's Phantom signs the USDC transfer.

The on-chain TX completes **before** the DB row is created, so the database always reflects committed on-chain state.

1. Admin fills form + submits → `POST /contests` (`ContestsController#create`)
   - Click-time prechecks: on-chain `Contest` PDA must not exist; creator's USDC must cover the prize pool. Insufficient-USDC modal includes a "Mint $500 Test USDC" recovery button.
   - Server builds a fully unsigned `create_contest` TX with both required signature slots reserved (admin payer + creator). Returns the unsigned TX + a signed `params_token`.
2. Client: `phantom.signTransaction(tx)` only. The browser serializes the Phantom-signed wire with the admin slot still empty and posts it back; it does not simulate, broadcast, or poll.
3. `POST /contests/finalize` (`ContestsController#finalize`) — collection route, no `:id`.
   - `Vault#assert_create_contest_cosign_safe!` semantically validates the signed wire against the server-issued payload (fee schedule, payouts, prize pool, lock timestamp, slug-derived PDA, expected accounts) before the admin key signs anything.
   - Rails admin-cosigns, simulates, broadcasts, waits for confirmation, then verifies via `verify_solana_transaction!` (OPSEC-010 — matches the `create_contest` discriminator + expected accounts).
   - Creates the DB row with `skip_onchain_callback = true` so the legacy `Contest#create_onchain!` after_create callback doesn't double-spend.

### Legacy server-only fallback

`Contest#create_onchain!` (via `after_create`) is preserved for Rails console / scripts / tests (`Rails.env.test?` auto-skips). The old `POST /contests/:id/prepare_onchain_contest` + `confirm_onchain_contest` endpoints still exist for backward compat and are referenced by `e2e/onchain.spec.js` — the production UI no longer uses them.

## Onchain Entry — three payment rails, one confirm gate

All three end at `Entry#confirm!` / `#confirm_onchain!`, which enforce the payment-proof (`tx_signature`), lock-time, exactly-`picks_required`, no-locked-games, per-user-limit, and sybil checks.

1. **Managed-wallet token-consume** — managed user with an `EntryTokenAccount`: `Vault#enter_contest_with_token` signs with the server-held keypair; consumes the token (no USDC moves), awards seeds, then `bust_entry_tokens_cache!`.
2. **Managed-wallet USDC** — `Vault#enter_contest` signs **both** the admin (payer) and user (server-managed keypair) slots and broadcasts directly. SPL transfer user-ATA → `op_rev` ATA. There is no DB-balance or PDA-balance deduction — neither exists in v0.16.
3. **Phantom-direct** — Phantom-FIRST (2026-06-06): `prepare_entry` selects an unconsumed token owned by `web3_solana_address` first and builds `enter_contest_with_token`; otherwise it builds the currency-funded `enter_contest`. Both wires are fully unsigned (admin reserved as fee-payer + nonce-authority but NOT signed) and the server records the funding choice plus token PDA on a `PendingTransaction`. Phantom signs first; the client POSTs the signed wire bytes to `confirm_onchain_entry`, which admits only the recorded instruction/funding pair, admin-cosigns (`Vault#cosign_and_broadcast_entry` via `Solana::Transaction.cosign_wire`), runs a `simulateTransaction` pre-flight, broadcasts **server-side**, then verifies (`TxVerifier`) and runs `Entry#confirm_onchain!`. `recover_pending_entry` resolves entries stranded by a mid-flight refresh (also TxVerifier-gated — Lazarus audit #1) and invalidates spent-token caches on both full verification and the already-active shortcut.

**Currency selection (2026-06-10)**: `prepare_entry` takes a strict `currency=usdc|usdt` param (default `usdc`). USDT is rejected unless the contest's `accepts_usdt` flag is set — only contests whose on-chain `entry_fee_by_currency` slot 1 was funded at creation accept it, and that array is **immutable** after `create_contest`, so contests created before 2026-06-11 stay USDC-only forever (the program rejects `currency_idx: 1` with `EntryFeeNotSet` 6027). The endpoint ensures the user's ATA for the SELECTED mint and threads `currency_idx` (0=USDC, 1=USDT) into `build_enter_contest` + the `PendingTransaction` metadata. Client: `#board-config` carries `acceptsUsdt`, the flow auto-picks USDC-first/USDT-fallback, and `eligibilityBlocker(session, neededCents, { acceptsUsdt })` only counts USDT funds on accepts-USDT contests.

(There is one unified `enter_contest` instruction — the old `enter_contest_direct` was removed in v0.16. Phantom users' navbar balance decreases live after the transfer; no DB balance is tracked for any wallet type.)

## Seeds System (On-Chain)

Seeds are awarded on-chain per the active **Season**'s `seed_schedule` (turf-vault v0.11.0+). Default schedule is `[25, 19, 14, 10, 7]` — entry index 0 → 25 seeds, index 4+ clamps to slot 4. No DB column for the seeds count — read from the `UserAccount` PDA via `Solana::Vault#sync_balance`. UI-derived levels: `level = seeds / 100 + 1` (`SEEDS_PER_LEVEL = 100`); class methods `User.level_for(seeds)`, `seeds_toward_next_level(seeds)`, `seeds_progress_percent(seeds)`. The active season is tracked in `SeasonConfig.current_season_id` (Rails singleton); the on-chain `Season` PDA lives at `[b"season", season_id_le]`. Compute an entry's award via `Solana::Vault.new.seeds_for_entry(entry_num)`. Progress-bar partial `_seeds_bar.html.erb` (navbar via `_user_nav` + contest show via `_slate_progress_xp`); level-up confetti; "Free Entry Earned 🎟️" badge in the entry-confirm modal. The level-up token is **minted automatically**: `LevelUpTokenMintJob` (every 15 min, `config/schedule.yml`) sweeps users whose `level` has outrun `entry_tokens_granted_level` and runs `Tokens::LevelUpGrant`, which mints one `EntryTokenAccount` per milestone under the **deterministic** `source_ref` `levelup:<user_id>:<level>`. Because the PDA is `sha256(source_ref)` and the program `init`s it, a repeat mint collides on-chain — so retries and overlapping sweeps cannot double-grant, and the chain itself is the ledger of which levels are paid. The sweep's candidate query is pure SQL against the denormalized mirror (partial index `index_users_on_pending_level_up_grants`), so an idle run issues **zero** Solana RPCs. The mint count is clamped to the same `owed` figure `/admin/free_entries` computes (`seeds / 100 - tokens.length`), so it never pays over an operator's manual mint — that page remains the manual backstop, its arithmetic unchanged. `User#level` column persisted via `update_level_from_seeds!` (`PATCH /account/update_level`).

The per-season schedule above is authoritative for Turf Monster; update this doc and the active `SeasonConfig`/vault setup together when changing rewards.

## Rake Tasks (`lib/tasks/solana.rake`)

- `solana:init_vault` — initialize the vault on devnet. Args `INIT=true SIGNERS=addr1,addr2,addr3 THRESHOLD=2` (optional `TREASURY=<squads_vault_pda>`, defaults to `SOLANA_SQUADS_VAULT_PDA` then the hardcoded Squads vault). OPSEC-013-gated in production. There is no `force_close` arg — the `force_close_vault` instruction was removed in v0.16; teardown = redeploy the program.
- `solana:health` — pre-flight before any cluster flip: genesis-hash match + program-exists-on-RPC + IDL-hash match. Exits non-zero on mismatch. **A check that could not RUN is reported as such, never as a tick** — the program-exists step reads `Solana::Vault.ensure_program_id_live!`'s tri-state return (`:live` / `:cached` / `:unverified`) rather than inferring a pass from the absence of a raise. That guard fails OPEN on purpose (`TokenPurchaseJob` depends on it), so against a rejecting endpoint the task used to print `✓ PROGRAM_ID exists on RPC` one line below `getGenesisHash failed`. It also passes `force: true`, so a ≤5-minute cache entry cannot answer for the CURRENT endpoint, and it builds its `Solana::Client` inside a rescue so a fat-fingered endpoint is diagnosed instead of raising past every check.
- `solana:idl_hash` — print the committed IDL's SHA256 (the value for `EXPECTED_IDL_HASH`).
- `solana:verify_idl` — run `verify_idl!` against the committed IDL.
- `solana:airdrop` — airdrop SOL to admin.
- `solana:check_balance` / `solana:check_admin_balance` — read on-chain SOL/USDC balances.
- `solana:mint_usdc` — mint test USDC to the admin ATA (`AMOUNT=<dollars>`, default 100). **Devnet only — hard-aborts on live production (OPSEC-020).** QA apps are exempt: they boot as Rails production but set `QA_ENV=true`, so `AppFlags.live_production?` reads false there and the devnet tooling stays usable.
- `solana:fund_wallets` — fund a set of wallets (dev bring-up).
- `solana:generate_keypair` / `solana:test_encryption` / `solana:reencrypt_managed_wallets` — managed-wallet key tooling (the last rotates ciphertext to the current `MANAGED_WALLET_ENCRYPTION_KEY`).
- `solana:reconcile` — run `Solana::Reconciler` over all users (on-chain account-presence / state checks; no pooled balance reconciliation).
- `solana:reconcile_contest CONTEST=<slug>` — compare an on-chain contest's entry count + slot-0 `entry_fees` against the DB.

## Public faucet endpoint

`/faucet` is a public route — GET renders a marketing page; POST mints test USDC to the requester's wallet via `Vault#mint_spl(amount_lamports, mint: Solana::Config::USDC_MINT, to: wallet)`. Used by the "Mint $500 Test USDC" recovery button in the insufficient-USDC modal during Phantom-driven contest creation. `FaucetController#claim` mints via `Vault#mint_spl` directly (not the `solana:mint_usdc` rake task) and guards itself: it raises "Faucet is production-disabled" when `Rails.env.production?` and requires `Config.devnet?`.

## RPC endpoints — server vs browser

There are **two** RPC endpoints, and mixing them up publishes a paid-provider
credential.

| | Constant / method | Env var | Who holds it |
|---|---|---|---|
| Server | `Solana::Config::RPC_URL` | `SOLANA_RPC_URL` | Rails, Sidekiq, rake. May carry an api-key. |
| Browser | `Solana::Config.public_rpc_url` | `SOLANA_PUBLIC_RPC_URL` | Every visitor, logged in or not. Must never carry a credential. |

**The bug this split closes.** Six surfaces used to emit `RPC_URL` verbatim into
the response body — `body[data-solana-rpc-url]` in `layouts/application` and
`layouts/modal_preview`, `#cosign-config[data-rpc-url]` on the three admin
cosign pages, and `@page_config[:rpc_url]` on `/proof-of-reserves`, which is
UNAUTHENTICATED and additionally renders the value as visible page text. On
`turf-monster-mainnet` that constant is a Helius endpoint carrying an `api-key`
query param, so every page load shipped the credential to every browser. The
`solana:health` / `solana:preflight` rakes had redacted the same constant before
printing it to a terminal since launch; the DOM was the one place that did not.

Redacting the CONSTANT is not the whole job. `Solana::Client::InsecureRpcUrlError`
and `URI::InvalidURIError` both embed the entire credentialed endpoint in their own
`.message` (the gem interpolates `@rpc_url.inspect`), so an exception printed or
logged raw republishes the key beside a correctly-redacted constant. Use
`Solana::Config.redact_message(e.message)` for any exception on this path —
`redact_rpc_url` returns `***` for a whole sentence, destroying the diagnostic.
`Solana::ClientLogger` applies the same redaction to `outbound_requests.endpoint`
and `.error_message`: failed RPCs always log, and a key rotation drives a burst of
failures, so that table was re-recording the OLD key at the moment of rotation.
(Rows written before that fix still carry it — purging them is an ops task.)

**Resolution order** (`Solana::Config.public_rpc_url`), each step checked
against `credentialed_rpc_url?`:

1. `SOLANA_PUBLIC_RPC_URL` — an endpoint provisioned *for* the browser.
2. `SOLANA_RPC_URL`, when it carries no credential. This is what keeps dev,
   test and QA byte-identical: their RPC_URL is the public devnet endpoint, so
   the browser receives exactly what it received before the split.
3. The cluster's canonical public endpoint (`PUBLIC_CLUSTER_RPC_URLS`).

Step 1 is **checked, not trusted**: a credential pasted into
`SOLANA_PUBLIC_RPC_URL` is dropped and logged (redacted), not served. The guard
bites at the emission, which is why this is a predicate and not just a renamed
variable.

`credentialed_rpc_url?` is deliberately broad and fails closed — any query
string (Helius `?api-key=`), any userinfo (`https://user:pass@…`), any opaque
path segment ≥20 chars (Alchemy `/v2/<key>`, QuickNode `/<hash>/`), or an
unparseable URL. A false positive costs a slower public endpoint and is fixed by
setting `SOLANA_PUBLIC_RPC_URL`; a false negative publishes a key.

**Operational note.** On mainnet, leaving `SOLANA_PUBLIC_RPC_URL` unset is
*safe* but *slow*: the browser drops to `https://api.mainnet-beta.solana.com`,
which rate-limits aggressively and is on the path for Phantom transaction
submission, `getSignatureStatuses` polling, and the proof-of-reserves balance
reads. Set it to a provider key that is safe to publish — a domain-restricted
key or a public-tier key — and treat it as public from the moment it is set.

**Not checked:** that the browser endpoint names the same *cluster* as
`SOLANA_RPC_URL`. Verifying that needs a genesis-hash round trip, which belongs
to the OPSEC-039 initializer (`config/initializers/solana_network_alignment.rb`)
and not to a render path. The defaults are network-keyed so omission cannot
cross clusters; an explicit `SOLANA_PUBLIC_RPC_URL` can, so set it per app.

Guards: `test/services/solana/public_rpc_url_test.rb` (the primitive) and
`test/integration/rpc_credential_not_in_browser_test.rb` (every browser surface,
plus a standing ban on any `.erb` or `app/javascript` file naming the server
constant at all).

## Boot alignment guard (OPSEC-039) and rotating the server RPC key

`SOLANA_RPC_URL` carries a provider key on mainnet, so it will need rotating.
That used to be unsafe. The alignment guard
(`config/initializers/solana_network_alignment.rb`) rescued exactly one class,
`Solana::Client::RpcError` — but an unauthorized provider answers with a body
that is not JSON at all, and solana-studio's `Solana::Client#call` runs
`JSON.parse(response.body)` with no rescue of its own. The resulting raw
`JSON::ParserError` walked past the rescue and **aborted boot**, including at
slug compile — so revoking the old key took the app down AND blocked the deploy
that would have fixed it. Enumerating the exception classes a hostile upstream
can produce was the mistake; there is no complete list.

The guard now separates two outcomes, and only one of them is fatal:

| Outcome | What it proves | Behaviour |
|---|---|---|
| Genesis hash came back and **disagrees** | the RPC really is a different cluster | **refuses to boot** (unchanged) |
| Unreachable, unauthorized, non-JSON, or no hash | nothing about alignment | logs at ERROR with the endpoint **redacted**, continues boot |

Refusing to boot on the absence of evidence turns a third-party outage into a
self-inflicted one, and this hook runs during slug compile, so it would take the
remediation path down with it. The degraded log line says the guard did not run;
the transaction paths surface the underlying error at the point of use.

**Rotation order.** Set the new `SOLANA_RPC_URL`, deploy, confirm
`bin/rails solana:health` is green, then revoke the old key. Revoking first is
now survivable — the app boots and logs `alignment check INCONCLUSIVE` — but
on-chain reads degrade until the new key is live.

`solana:health` carries the same widening, so on a rejected key it reports
`getGenesisHash failed: JSON::ParserError` and still reaches its verdict instead
of aborting at step 2 with a stack trace.

Guards: `test/initializers/solana_network_alignment_test.rb` (drives the real
initializer against real non-JSON bodies over a real socket, and asserts BOTH
halves — the indeterminate cases boot, a real mismatch still refuses) and
`test/tasks/solana_health_unauthorized_rpc_test.rb`.

## Solana Auth Security

- **SIWS / nonce replay prevention**: Solana sign-in nonces include a timestamp with an enforced 5-minute expiry; the nonce is deleted from the session before verification (delete-before-verify) to prevent replay. Signature verification is host-bound (`Solana::AuthVerifier`, OPSEC-018).
- **TX verification**: `Solana::TxVerifier` binds a submitted signature to the expected instruction + signer + server-re-derived PDA before any DB state is credited (OPSEC-010).

## Error namespace

turf-vault custom errors start at **6000** (`errors.rs`). Anchor framework **3000-range** errors (e.g. 3012 `AccountDidNotDeserialize`) signal **schema drift** between the deployed program and an on-chain account — i.e. an IDL/layout mismatch — **not** a vault error. Key codes: `ContestNotOpen` 6003, `ContestAlreadySettled` 6006, `SettlementOverflow` 6008, `ContestNotCancellable` 6029, `ContestLocked` 6034, `ContestConcluded` 6035. Several codes (6011/6012/6017/6019/6028) are retired-but-kept for numbering stability.
