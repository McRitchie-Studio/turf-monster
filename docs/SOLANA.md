# Solana Integration

"DeFi mullet" — Web2 UX front, Solana settlement back. **Read paths** rescue-and-log (balance/seeds display falls back to 0 on RPC error). **Money-mutating paths** (create_contest, enter, settle) are TX-first — the on-chain transaction confirms *before* the DB row is promoted (create_contest does write a `pending` row first, as a write-ahead record, so a broadcast never lands with nothing pointing at it; it is promoted to `open` only after verification) — and fail closed: `Solana::Vault.ensure_program_id_live!` raises if `PROGRAM_ID` isn't on the RPC, and `Solana::Config.verify_idl!` refuses to boot/precompile in prod on IDL drift. The app does not transact against a missing or IDL-mismatched program.

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
- `Solana::Keypair` — Ed25519 keygen, sign, base58, and encrypt/decrypt of managed-wallet secrets via a 256-bit key derived from the **`MANAGED_WALLET_ENCRYPTION_KEY`** env var (OPSEC-015; `secret_key_base[0,32]` is a legacy fallback only). During a key rotation, **`MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS`** also opens rows sealed under the retiring key — it never seals. See [Rotating the managed-wallet key](#rotating-the-managed-wallet-key-managed_wallet_encryption_key). `#inspect`/`#to_s` are redacted (OPSEC-021).
  - **`Keypair.admin` and credentials in TEST.** `SOLANA_ADMIN_KEY` and `RAILS_MASTER_KEY` are GitHub **repository** secrets. Dependabot PRs run against the separate **Dependabot** secret store and cannot read repository secrets *by design*, so every dependency PR on this repo failed the Solana unit tests permanently — no rebase or re-run could clear it. The real defect was that unit tests which only *assemble* and *encrypt* demanded a production credential. Under **`Rails.env.test?` only**, `Keypair.admin` now falls back to a fixed non-secret keypair (`TEST_ADMIN_SEED`) and the legacy encryptor falls back to `TEST_SECRET_KEY_BASE`. **Outside test both remain a hard raise** — `Keypair.admin` is the Xan signer (1-of-3 on the vault multisig; fee payer for `create_contest` / `enter_contest` / `mint_entry_token`), and a signing path that silently substituted a throwaway key would be far worse than a red CI. `Rails.env` is the discriminator on purpose: a marker like `ENV["CI"]` can be set anywhere, including on a production dyno. Pinned by `test/services/solana/keypair_admin_fallback_test.rb`, which asserts the raise still fires in `production`, `development`, and `staging`.
- `Solana::Vault` — high-level builders + senders for the current TurfVault instruction surface (see table below). Managed-wallet paths sign server-side; Phantom paths build partial transactions for browser/user signatures plus server cosign where required. `sync_balance` surfaces the user's USDC ATA balance (back-compat `:balance` key) + decodes `seeds` from the `UserAccount` PDA; `fetch_wallet_balances` reads USDC/USDT ATAs; `ensure_program_id_live!` guards stale env.
- `Solana::TxVerifier` — fetches a confirmed TX and asserts it touches `PROGRAM_ID` with the expected Anchor discriminator + signer + writable PDA (OPSEC-010). Defeats "submit any successful signature."
- `Solana::ErrorInterpreter` — maps on-chain error codes into the JS eligibility-blocker `{reason, mode, data}` shape. Friendly mappings include the v0.15.1 username codes `6020`/`6021`/`6022` (UsernameReserved / UsernameInvalidChars / UsernameTooShort) and `6027` EntryFeeNotSet (entering with a currency the contest's `entry_fee_by_currency` never funded); `app/javascript/solana_errors.js` (`parseSolanaError`) mirrors the same codes client-side.
- `Solana::Reconciler` — compares **on-chain contest state** (entry counts, slot-0 `entry_fees`) and per-user on-chain account presence against the DB; writes discrepancies to `ErrorLog` only. **No** Slack/Discord webhook. The scheduled cron was **removed 2026-05-19 (OPSEC-040)** — run ad-hoc via the rake tasks below.
- `Solana::ClientLogger` — prepended onto the RPC client to write `OutboundRequest` audit rows.

Money-path reconcilers live outside `solana/` but read the chain the same way. All three are **read-only on chain** — they resolve an ambiguous Rails row against what the chain already says, and none of them signs, broadcasts, transfers or mints:
- `Contests::PendingReconciler` — stranded `pending` **Contest** rows (a crash between `#finalize`'s write-ahead save and its promote). Promote / delete / flag, keyed on whether the derived Contest PDA exists. See the contest-creation section below.
- `Entries::OnchainReconciler` — `cart` **Entry** rows whose on-chain consume already settled (the 2026-06-08 incident, entry #133). Rooted in Contest rows, which is why it could never reach a contest-level strand.
- `Deposits::OnchainReconciler` — stranded `pending` **TransactionLog** deposit rows (die-after-claim in `StripeDepositJob`). Confirms the recorded signature; never re-transfers.

RPC + serialization primitives come from the **`solana-studio` gem** (`~> 0.5.3`, per `Gemfile`), not local: `Solana::Client` (JSON-RPC over Net::HTTP, retry/blockhash logic), `Solana::Borsh`, `Solana::Transaction` (builder, `find_pda`, `anchor_discriminator`, partial signing), `Solana::SplToken`.

## Anchor Program (`turf-vault/`)

Separate project at `/Users/alex/projects/turf-vault/`. Current deployment identity is canonical in `turf-vault/docs/CURRENT_DEPLOYMENT.md`; do not copy stale program IDs or signer keys from old launch notes.

- Devnet program ID: `EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ`
- Mainnet program ID: `DaFv83yokwTz8msP9CzJ13eazSGk15NuUTxjkfzJzxMM`
- The two are DIFFERENT programs, and the admin deployment-state card (`app/views/contract/_section_admin_state.html.erb`) must say so. Its Program ID caption read "Same on devnet + mainnet builds" from the page's first commit until card-claims-program-invariance; it now names the cluster this build runs on, off the same `Solana::Config::NETWORK` read the Upgrade authority caption uses. Guarded by a RENDERED assertion in `test/views/contract_program_id_caption_test.rb`, which drives the real page under both cluster configurations and requires the two captions to differ — a source grep would pass on a card that stopped emitting the caption at all.
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
| `set_contest_lock_time` | **1-of-3** | Set/clear `lock_timestamp` (v0.17 derived lock; `0`=no lock). Rejected once settled/cancelled or past `conclusion_timestamp`. **Rails signs this with the operator's Phantom, not the bot** — see the note below. |
| `set_contest_conclusion_time` | **1-of-3** | Set/clear `conclusion_timestamp` (v0.18); once chain time passes it, the lock time is final. **Phantom-signed from Rails**, same note. |
| `enter_contest` | **user-signed** + **1-of-3** payer | Paid entry: SPL-transfer fee user-ATA → `op_rev` ATA, init `ContestEntry`, award seeds, bump `entry_fees`/`current_entries`. One path serves Phantom (user signs) + managed (server signs both slots). |
| `enter_contest_with_token` | **user-signed** + **1-of-3** payer | Token-funded entry: consume an `EntryTokenAccount` (no SPL transfer), award seeds. `currency_idx = 255` sentinel; does **not** bump `entry_fees` (intentional v1 gap). |
| `mint_entry_token` | **1-of-3** | Mint a pre-purchased free-entry voucher `[b"entry_token", sha256(source_ref)]` (`source`: operator/Stripe/MoonPay). Not pause-gated. |
| `burn_entry_token` | **1-of-3** | Void an unspent voucher (operator claw-back); the holder does **not** sign. Not pause-gated. TOMBSTONE, not close: the account survives with `consumed = true` and `BURNED_FLAG` (`0x80`) raised in the spare high bit of `source`, so the on-chain token COUNT Rails reads as owed is unchanged and nothing re-mints it. No layout change — `EntryTokenAccount` stays 124 bytes. Rejects a double burn and a token already spent. **In source, not yet on mainnet** — absent from **both** pinned IDLs (`config/turf_vault.idl.json` and `config/turf_vault.mainnet.idl.json` each carry 22 instructions and no `burn_entry_token`) until the next Squads upgrade re-pins them. |
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

- **1-of-3 vault signer** (`vault_state.is_signer(key)`) — routine ops: `create_contest` (payer), `set_contest_lock_time`, `set_contest_conclusion_time`, `close_contest`, `mint_entry_token`, `burn_entry_token`, `create_season`, `grant_seeds`, admin username reserved-prefix waivers, and the **payer** slot of `enter_contest{,_with_token}`. Driven by the always-online Xan server key.
  - **The two contest time-setters are 1-of-3 ON CHAIN but Phantom-signed FROM RAILS.** The program escalates to 2-of-3 only once a deadline has PASSED, so a single key can still EXTEND a window that has not shut — push a 1pm lock to 4pm at 12:59, then enter at 3pm with results known. Rather than wait for the program's upgrade window, the app moved the operator route off the server key: `ContestsController#prepare_lock_time`/`#prepare_conclusion_time` build a TX the admin's own Phantom signs (bot = fee payer only), and `#lock`/`#update` REFUSE an on-chain contest. `Solana::Vault#set_contest_lock_time`/`#set_contest_conclusion_time` survive for the unattended QA rehearsal lane, which has no wallet to prompt; they retire when devnet's five-signer set gives three slots to agent-owned keys.
    - **The Phantom route carries the whole capability, not just the quick buttons.** `#prepare_lock_time` takes EITHER `in_seconds` (relative, clamped `0..3600` — the "Lock now" / "Lock in 60s" buttons) OR `lock_timestamp` (absolute Unix seconds, unclamped — an NFL flex reschedule days out). `lock_timestamp: 0` CLEARS the lock, the program's own contract, and `#confirm_lock_time` mirrors that as a nil `starts_at`. Both shapes had to exist before the server-signed path could be retired: it sent an unclamped absolute value and used `0` to re-open entries, so a relative-only Phantom endpoint would have removed operator capability rather than relocating it.
    - **An on-chain contest's edit form does not carry its lock.** `contests/edit.html.erb` omits `contest[starts_at]` entirely for a verified contest and renders Phantom "Set lock time" / "Clear lock" controls instead. This is load-bearing, not cosmetic: `contest_lock_picker`'s `sync()` truncates seconds and `init()` writes on page load, so a hidden field there resubmitted a slightly-earlier deadline on a plain rename and `#update` refused it as a lock move.
  - **`burn_entry_token` is the only 1-of-3 op that destroys user property**, and it is irreversible: nothing in the program clears `BURNED_FLAG`, and the surviving tombstone PDA makes a re-mint on the same `source_ref` collide on `init`. `pause` does not gate it. A leaked Xan key can therefore void every unspent voucher on the platform — see `turf-vault/docs/KEY_ROTATION.md` §"Threat-model note".
- **2-of-3 multisig** (`vault_state.validate_multisig(admin, cosigner)`, distinct signers) — treasury/governance ops: `settle_contest`, `cancel_contest`, `register_currency`, `deactivate_currency`, `sweep_operator_revenue`, `pause`, `unpause`, `update_signers`.
- **User signature** required for `set_username` and the **user** slot of `enter_contest{,_with_token}` (the user must consent to spending from / consuming their own funds — OPSEC-004).
- `create_user_account` is permissionless (payer only); `initialize` is gated to `INIT_AUTHORITY` on mainnet builds.

Signers (`VaultState.signers`, threshold 2) — the same set on **devnet and mainnet**, re-verified on-chain 2026-09-05 in both `VaultState` PDAs:
- Xan (server) — `8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd`
- Mr. McRitchie (human Phantom, = `INIT_AUTHORITY`) — `7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr`
- Mason — `CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR`

### turf-vault v0.26 — governance-as-data, and how Rails carries TWO program shapes

v0.26 is on turf-vault's `accepted` branch and **is not deployed** — mainnet and
devnet both still run v0.25. It rewrites the auth model: up to five signer
slots, per-action signature thresholds stored in a `GovernanceConfig` PDA rather
than baked into the instruction shape, a per-window cap on free-entry minting,
and an on-chain username registry.

For Rails the consequence is narrow and severe: **every vault-authorized
instruction gains a `governance` account**, plus `treasury` on `close_contest`,
`window_index` + `mint_window` on `mint_entry_token`, `invitee_user_account` on
`grant_seeds`, and `username_record` on the two username paths. Anchor account
lists are POSITIONAL, so the two shapes are mutually unintelligible: a v0.26
wire sent to the live v0.25 program is rejected, and a v0.25 wire sent to an
upgraded program is rejected too.

#### Why this app is version-aware rather than upgraded in lockstep

"Update Rails before the deploy" and "upgrade the program before Rails" are the
same outage in opposite directions. Shipping the new account set while v0.25 is
live breaks the entire on-chain surface exactly as surely as upgrading the
program first would.

So the slug carries BOTH shapes and picks one at boot:

| `SOLANA_VAULT_GOVERNANCE` | shape | IDL selected (by cluster) |
|---|---|---|
| unset (the default), `off`, `0`, `false`, `no`, `disabled` | v0.25 | `config/turf_vault.idl.json` · `config/turf_vault.mainnet.idl.json` |
| `on`, `1`, `true`, `yes`, `enabled` | v0.26 | `config/turf_vault.v026.idl.json` · `config/turf_vault.mainnet.v026.idl.json` |
| present but anything else, **including empty** | — | **refuses to boot**, naming the variable |

- **The default is OFF because OFF is what is deployed.** An absent variable
  resolves to the shape the chain actually speaks, so merging and deploying this
  code changes nothing in production.
- **Present-but-garbage raises.** `ENV.key?` distinguishes absent from
  set-to-nonsense — the precise hole that `empty-solana-network-fails-open`
  closed for `SOLANA_NETWORK`. A typo must not silently mean "off" on the one day
  someone meant to turn it on.
- **The switch can pick a VERSION, never a CLUSTER.** `IDL_PATH`'s basename is
  still decided by `SOLANA_NETWORK` alone; the switch only appends a suffix.
  Pinned by `test/services/solana/config_network_required_test.rb`.
- **`Solana::Config.verify_governance_alignment!` refuses a boot where the
  switch and the pinned IDL disagree**, and is deliberately NOT covered by
  `BYPASS_IDL_CHECK` — that hatch exists for hash SKEW, where the shape is right
  and only the pin is stale. A wrong shape has no legitimate override.

#### The version string is not the discriminator

turf-vault built v0.26 with `version = "0.25.0"` still in
`programs/turf_vault/Cargo.toml`, so **both IDLs report `metadata.version`
`0.25.0`**. Anything keying on that string looks correct and selects the wrong
shape. `Solana::Config.idl_declares_governance?` therefore probes STRUCTURALLY —
for an `init_governance` instruction, which exists only in v0.26 and which nobody
hand-maintains. (turf-vault should bump that version; until it does, do not
reintroduce a version-string check.)

#### IDL hashes — re-pinned from the BUILT IDL

Built with `anchor-cli 0.32.1` at turf-vault `f3edc88`:

```bash
anchor idl build -o config/turf_vault.v026.idl.json
anchor idl build -o config/turf_vault.mainnet.v026.idl.json -- --features mainnet
```

Never `anchor idl fetch` — a Squads deploy does not update the on-chain IDL, so a
fetch returns the OLD one and the pin would certify the wrong shape.

| file | SHA256 |
|---|---|
| `config/turf_vault.idl.json` (v0.25 devnet, **unchanged**) | `f11446facec1043cb15b169929aaff3da9e955e05f3c462e86c7b584706246e9` |
| `config/turf_vault.mainnet.idl.json` (v0.25 mainnet, **unchanged**) | `b9b522635894a42f5434f1faa1cd126d146f3042ae2c233acd1dd76a300f7152` |
| `config/turf_vault.v026.idl.json` (devnet) | `259889ced686875b46062aaabce7e8c45e68710e6c0ae0738f3451cd4673060f` |
| `config/turf_vault.mainnet.v026.idl.json` (mainnet) | `d1eea2a48d0a7f0cf711d3da7c85a1653d13e0903be6bebcf7be47be41404ea7` |

Error codes span **6000-6066** (67 variants, up from 45), and three new account
types appear: `GovernanceConfig`, `MintWindow`, `UsernameRecord`. The instruction
count goes 22 -> 28: eight added, and `admin_create_user_account` +
`admin_set_username` **DELETED** (not deprecated — Rails never called either, and
`test/services/solana/vault_account_layout_test.rb` keeps it that way).

#### v0.26 signature thresholds

Thresholds are DATA (`GovernanceConfig`), retunable by one `set_action_threshold`
transaction, some with immovable floors. What changes for Rails:

| action | today | v0.26 | Rails supplies | consequence |
|---|---|---|---|---|
| `create_season` | 1 | **3** | admin + 2 in `remaining_accounts` | admin UI cannot create a season alone |
| `close_contest` | 1 | **2** | admin + 1 | **the unattended close path stops working** |
| `set_contest_lock_time` / `..._conclusion_time` | 1 | **2** (3 to re-open/amend) | admin + 1 | **the QA rehearsal's unattended set stops working** |
| `burn_entry_token` | (never deployed) | **3** | admin + 2 | operator claw-back needs three |
| `settle_contest` · `cancel_contest` · `sweep_operator_revenue` | 2 | **3** | admin + cosigner + 1 | the settle cosign flow needs a third wallet |
| `register_currency` · `deactivate_currency` · `unpause` | 2 | **3** | admin + cosigner + 1 | |
| `pause` | 2 | **2** | unchanged | the brake stays cheapest, by design |
| `mint_entry_token` within the day's cap | 1 | **1** | unchanged | Stripe fulfilment untouched |
| `mint_entry_token` above the cap (250/day) | — | **3** | admin + 2 | a mint spike asks for three humans |
| `grant_seeds` · `create_contest` · `enter_contest{,_with_token}` | 1 | **1** | unchanged | the player-facing paths are untouched |

**Extra signatures ride as LEADING `remaining_accounts`** — for this raw client,
metas appended after the named list, each `is_signer: true`.
`instructions::governance::authorize` takes exactly `threshold - named.count` of
them. For `settle_contest` they come BEFORE the winner triples.

Rails REFUSES locally rather than broadcasting a doomed transaction: a
server-signed path that cannot reach its threshold raises
`Solana::Vault::ThresholdUnreachableError`, naming the action, the numbers and
the remedy. The on-chain alternative is `InsufficientSigners` (6046) after the
fee is already spent.

That guard counts **distinct** keys across the instruction's named slots plus
the extras it was handed, because `VaultState::validate_threshold` counts
distinct members and rejects a repeat outright (`DuplicateSigner`) — the same
keypair signing twice is one signature. `settle_contest` is the one builder with
two named slots (admin **and** cosigner), and it is also the one whose "no
cosigner" spelling puts the admin key in both; a list that is two keys but one
key is refused here rather than on chain.

#### Collecting the third signature — one session, two Phantom approvals

The six raised OPERATOR paths (`settle_contest`, `cancel_contest`,
`sweep_operator_revenue`, `register_currency`, `deactivate_currency`, `unpause`)
are cosigned in the browser, not by the server, so the threshold rise lands as a
UI problem: the server contributes ONE signature (the admin key, patched into
its slot by `Transaction.cosign_wire` after the fact) and the browser must now
come back with TWO instead of one.

**The flow.** The operator picks the second wallet on the page BEFORE clicking —
the extra signer slots are part of the message and cannot be added once the
first wallet has signed. `#rebuild` reserves them (`extra_cosigners:`) and
returns the plan with the bytes. `cosign_signatures.js` then collects one
signature per wallet in slot order, waiting between them while the operator
switches accounts in Phantom, and merges them onto one transaction.

**Phantom is never trusted to preserve a signature it did not make.** Each
wallet signs a FRESH decode of the same bytes; only its own 64 bytes are
extracted, and the signatures are merged with `addSignature`. Phantom's
sign-only method is documented legacy with an unpinned return shape — turf-vault's
own operator console (`docs/vault-console.html`) declined to claim a multi-wallet
collection flow for exactly that reason — so nothing here depends on what it
does with a partially-signed transaction it is handed.

**Why ONE SESSION and not a half-signed row handed between sessions.** A
multi-session collection needs a transaction that does not expire, which means a
durable nonce, and **a durable nonce cannot anchor a Phantom-signed
transaction**. A nonce transaction is only recognized when
`advanceNonceAccount` is instruction 0, and Phantom injects Lighthouse guard
instructions at positions the app does not control; when one lands ahead of the
advance, validators read the nonce value as an unknown blockhash and reject at
preflight. That is the 2026-06-11 mainnet incident recorded in
`Solana::Vault#build_enter_contest`, and it is why `#simulate_and_broadcast`
says the same thing.

So these six stay on a fresh recent blockhash, minted at click time, and the
collection window is the ordinary ~60-90s. **No extra nonce accounts are needed
— and the single production nonce must NOT be extended to these paths.** It
serves exactly one caller today (`build_create_contest` on its `admin_signs:
true`, server-signed branch); pointing Phantom flows at it would add contention
to a resource that cannot help them anyway.

> A note for whoever reads this next: the comment in `#build_enter_contest` used
> to end "the durable nonce remains for OPERATOR flows … where a slow human
> cosign is the actual problem." **That was never true of the code** — no builder
> reached through `build_partial_signed` has ever passed `durable_nonce:` — and
> it is the sentence that made a multi-session design look available. It has been
> corrected in place.

**If two approvals inside 90 seconds proves impractical in practice**, the fix is
NOT more nonce accounts. It is either an out-of-band ceremony for the rarest of
the six, or solving the Lighthouse ix-0 ordering problem first — a wallet-behaviour
investigation, not a Rails change.

#### The mint cap is the one threshold that moves during the day

`mint_entry_token` is 1 signature inside the window's cap and 3 above it, so an
unattended path does not fail on deploy — it fails partway through a busy day,
permanently until the window rolls. `Solana::Vault#mint_entry_token` therefore
reads the count the program itself keeps (`MintWindow.minted`, at
`[b"mint_window", window_index]`) and raises
`Solana::Vault::MintWindowCapReachedError` — a `ThresholdUnreachableError`
subclass — before broadcasting. `#mint_window_usage` exposes the same numbers
(`minted`, `cap`, `remaining`, `resets_at`) to callers that want to ask first.

Two consequences worth knowing before the ceremony:

- **Fiat checkout refuses BEFORE the charge.** `TokenPurchaseJob` mints *after*
  the card is charged, so a cap hit there is a customer who paid and got
  nothing, with retries that cannot heal inside the window.
  `TokensController#mint_budget_refusal` gates all four rails (Stripe, PayPal,
  Coinflow, Aeropay) at order creation and refuses a pack the window cannot
  cover. It narrows the race rather than closing it — a checkout opened with
  room can still complete after the cap fills — so the job-side refusal stays as
  the backstop and files an `ErrorLog` against the purchase. **Nothing is
  auto-refunded:** re-running the job after the window rolls resumes at
  `already_minted` and completes the order.
- **The level-up sweep yields the last slots.** It is the only fully unattended
  grinder on the mint (a 15-minute cron), so it stops at
  `cap - Solana::Vault::UNATTENDED_MINT_WINDOW_RESERVE` and leaves the tail for
  paid fulfilment. A level it defers is paid on the next pass; a purchase
  refused after the charge is not.

Both behave correctly with `SOLANA_VAULT_GOVERNANCE` off, which is the
production default today: in the v0.25 shape there is no cap, and the guard
issues no RPC at all.

#### THE 3-OF-3 GAP — what breaks between the upgrade and the signer rotation

At deploy, `VaultState.signers` is still **three** keys, so every action raised
to threshold 3 is **3-of-3** until `update_signers` widens the set to five.
Nothing with fewer than all three signatures works, and there is no slack for a
lost key. Specifically:

- **The QA rehearsal driver breaks.** `lib/turf_monster/qa_rehearsal/driver.rb`
  `#cosign_with_agent` loads a second key and settles a contest unattended at
  2-of-3. `settle_contest` becomes 3, and the driver's KeyStore cannot reach a
  third VAULT signer, so `conclude --cosign agent` fails with
  `InsufficientSigners`. Its `#conclude` also calls the server-signed
  `set_contest_lock_time`, now 2 — that fails first.
- **`close_contest` becomes two-signature**, so the unattended close in
  `ContestsController` and `driver.rb#close_contest` both stop.
- **Admin season creation stops** until three wallets are present.
- **`pause` still works at 2, and `unpause` needs 3** — deliberate, so a
  compromised pair can pull the brake but never release it.
- **Mint-under-cap and Stripe fulfilment are untouched — until the cap.** The
  first 250 mints of a window are still one signature, so nothing breaks on the
  day of the upgrade. The 251st needs three, which no agent-reachable set can
  produce during the gap **or after it** (over-cap is 3 permanently, by design —
  the signer rotation widens the set, it does not lower this bar). Rails refuses
  that mint locally and fiat checkout refuses the purchase before charging; see
  "The mint cap is the one threshold that moves during the day" above. Watch
  `remaining` on a heavy grant day.

#### Upgrade ordering — UNFORGIVING

Four steps, and the numbers are the order. **Tightening `EXPECTED_IDL_HASH` is
NOT one of them** — it is a separate, later act that ends the cheap rollback, and
it has its own preconditions under "Tightening the pin — the one-way door" below.

1. **Squads upgrade** (`turf-vault/scripts/squad-upgrade.js`). The script reads
   the multisig's live members, masks and threshold and refuses BEFORE it spends
   a lamport if the keys in hand cannot both approve and execute — a run that
   dies at the approve step has already paid for `ExtendProgram` and stranded a
   buffer. On **devnet it runs unattended**; on **mainnet it stops at a handoff**
   for Mr. McRitchie's approvals. Which one you get is decided by the membership
   recorded under "Program Upgrades — Squads multisig" below; read it there
   rather than assuming, and re-derive it from chain on the day.
2. **`init_governance` IMMEDIATELY.** Every vault-authorized instruction requires
   that PDA — `pause` INCLUDED — so between the upgrade and this call the platform
   has NO BRAKE. `turf-vault/scripts/init-governance.js`; `--cluster` is required
   and has no default. It takes NO arguments, which is what makes its
   2-signature bootstrap safe: it can only write the shipped defaults.
3. `heroku config:set EXPECTED_IDL_HASH="<v0.25>,<v0.26>" SOLANA_VAULT_GOVERNANCE=on`
   and restart. Widening the allow-list first means no unverified window across
   the flip — and **leaving it widened is what keeps the rollback one command.**
4. **`update_signers` to widen the set to five** — this is what closes the 3-of-3
   gap. **It cannot be pulled earlier than step 1.** v0.25's `VaultState` holds
   THREE signer slots, and a five-key `update_signers` sent to the deployed
   v0.25 binary SUCCEEDS: it silently truncates to the first three, under a
   green simulation. Nothing fails at send time, and the two keys you believe
   you added are simply absent the next time an action needs them.

**Rollback is `heroku config:unset SOLANA_VAULT_GOVERNANCE` plus a restart** —
seconds, no deploy, no second ceremony. It returns Rails to the v0.25 shape —
which after step 1 means a booting app, not a working one; read "What the
rollback actually buys" below before you rely on it.
Step 1 is the point of no easy return: rolling the PROGRAM back is a second
Squads act. **Steps 2-4 are reversible from the Rails side alone for exactly as
long as `EXPECTED_IDL_HASH` still accepts the v0.25 hash** — which is why the
tighten is not in the list above.

#### What the rollback actually buys — a BOOT, not a working app

Say this part plainly, because "one-command rollback" invites the wrong reading.
**Before** the program upgrade, unsetting the switch is a true rollback: Rails
returns to the shape the chain is still speaking, and everything works.
**After** step 1, it is not. It buys a booting app that cannot transact.

Anchor account lists are POSITIONAL, so a v0.25-shaped wire sent to a v0.26
program is rejected. Measured from the two committed IDLs: the shapes share
**20 instructions, and 19 of them have a different account list in v0.26** — 17
by gaining `governance`, plus `create_user_account` (`+username_record`) and
`set_username`. The only shared instruction whose account list is unchanged is
`initialize`, a one-time bootstrap. There is no meaningful subset that survives.

The read side survives almost intact, and that is the trap rather than the
consolation. Of the seven account types both shapes declare, five are
byte-identical. The two that changed do not grow: they **spend trailing
`_reserved` padding**, so every pre-existing field keeps its byte offset and a
v0.25 decoder reads the new field as padding it already ignores.
`UserAccount` takes one byte of its 32 for `username_registered` (32 -> 31);
`VaultState` takes all 64 of its reserve for `signers_ext`, two more pubkeys
(64 -> 0). So a rolled-back app renders pages and shows balances while every
entry, settle, mint, pause and season write fails on chain.

`VaultState` is worth pausing on, because it is the same fact as the step-4
warning above: the base `signers` array is THREE slots in BOTH shapes, and
v0.26's extra two live in `signers_ext` — a field the deployed v0.25 binary
does not have. That is why a five-key `update_signers` against it writes three
and drops two instead of failing.

**So the boot-level rollback is worth having and is not a retreat.** It is the
difference between an app that crash-loops with no `/up`, no admin, and no way
to read state, and an app you can log into while you decide what to do —
including proposing the second Squads act that rolls the PROGRAM back. Keep it.
Just do not plan around it as though it restored service.

#### Tightening the pin — the one-way door

Tightening `EXPECTED_IDL_HASH` to the v0.26 hash alone **forfeits the
one-command rollback.** This is measured, not reasoned: the switch picks the IDL
file, the allow-list then judges whatever file the switch picked, and a pin that
names only v0.26 refuses the v0.25 file the rollback selects.

| `EXPECTED_IDL_HASH` | `SOLANA_VAULT_GOVERNANCE` | IDL selected | boot |
|---|---|---|---|
| `<v0.25>,<v0.26>` | `on` | v0.26 IDL | boots |
| `<v0.25>,<v0.26>` | unset | v0.25 IDL | **boots — this is the rollback** |
| `<v0.26>` | `on` | v0.26 IDL | boots |
| `<v0.26>` | unset | v0.25 IDL | **`IdlMismatchError` — release phase and every web dyno refuse to boot** |
| `<v0.25>` | `on` | v0.26 IDL | **`IdlMismatchError` — the same brick, mirrored** |

Measured 2026-09-15 against this tree; `test/docs/governance_rollback_pin_test.rb`
re-derives every row from the real guard and the real IDL files, so a future
change that breaks one reddens there rather than on a dyno.

**So why tighten at all?** Because the widened pin cannot tell a deliberate
retreat from an accidental `config:unset`. Both produce byte-identical state:
the v0.25 file selected, its hash allow-listed, and
`verify_governance_alignment!` satisfied — because the switch and the file agree
with EACH OTHER even though neither agrees with the upgraded program. Nothing
refuses that boot, and what follows is the 19-of-20 failure described above: an
app that looks healthy and cannot write. Tightening is how you finally say "we
are not going back", and it converts that silent misconfiguration into a loud
boot refusal. It buys strictness at the exact moment you would most want the
boot, so it is worth its cost only once retreating is off the table.

**What tightening does NOT buy is tamper-detection** — the pair pin costs
nothing there, which is worth stating because it is the intuitive objection.
`verify_governance_alignment!` reads the selected file's CONTENTS, runs ahead of
the `BYPASS_IDL_CHECK` return, and never consults the allow-list at all, so it
already pins which of the two files each switch position may select. A two-hash
set therefore admits exactly ONE file per switch position, the same as a
one-hash set; what the second hash admits is the other position, which is the
whole point. Do not weaken that guard to make a rollback work — it is the one
thing standing between a wrong shape and a dyno that accepts traffic.

**Tighten when all of these hold, and not before:**

- Step 4 (`update_signers`) has landed, so the v0.26 shape is fully operable.
- The v0.26 shape has carried real traffic — at minimum one contest through
  `close_contest` and one `settle_contest` — on the cluster being tightened.
- You have decided you will not retreat. If you would still consider it, the
  widened pin is the correct state and costs you one allow-listed hash.
- **You accept that `bin/deploy` will undo it at the next IDL bump.** The script
  agrees with this section and says so in its own comment: its automated tighten
  writes the hashes this slug ships for the target cluster — **both switch
  positions** — precisely so an `unset` still boots. It asks
  `lib/solana/idl_selection.rb` which file the TARGET boots against, the same
  rule `Solana::Config` applies to its own ENV at boot, so there is no second
  implementation to drift. A routine deploy with no IDL bump rewrites nothing
  and leaves a manual tighten standing; the next deploy that DOES bump the IDL
  widens, pushes, and then re-pins both shapes of the new pair. A hand-tightened
  pin is therefore a temporary state with an expiry you do not control — which
  is the strongest argument that the dual pin, not the single one, is this
  system's resting state.

Tighten as its own change, with its own restart, and confirm the app boots
before walking away.

### Program Upgrades — Squads multisig (OPSEC-002, 2026-05-19+)

**`anchor deploy` no longer works.** The program upgrade authority is a Squads V4 multisig vault — distinct from `VaultState`'s in-program multisig — not a single keypair. **Each cluster has its own vault PDA**: devnet `BW13kgfiG2koFn3WRkte21NW9TFygsD1ge2fNJdjH6kC`, mainnet `Bk9sS7iiSRL18vuo2KVzkeGw7EekKqxMCjrdoyGGdJm`. Every upgrade goes through the Squad. Running `anchor deploy` will fail because the Solana CLI signs as a single keypair that is no longer the upgrade authority.


**Membership and threshold — stated here once, for both clusters.** Every other
mention in this doc defers to this paragraph; a second number written down
somewhere else is how this section spent four review rounds disagreeing with
itself. Re-measured **on chain** at `finalized` on **2026-09-15**, through two
independent RPC providers and a raw-byte check of the member offsets: each
multisig carries **five members and a threshold of three**, and all five hold
mask `7` (`Initiate|Vote|Execute`) — so there are five voters against a
threshold of three, with two to spare on either cluster. Re-read at `finalized`
on 2026-09-16, membership and config-transaction history on both clusters:
unchanged.

**The two clusters do not carry the same five.** Three seats are shared
(`3Qj4v9…`, `7ZDJ…`, `BLSBw8…`); the other two differ:

| | devnet `7nRuVw3V…` | mainnet `4H3fP3ot…` |
|---|---|---|
| shared | `3Qj4v9…`, `7ZDJ…`, `BLSBw8…` | `3Qj4v9…`, `7ZDJ…`, `BLSBw8…` |
| cluster-only | `2eGs8G3w…` (`solana.turf.system.devnet`), `8K81…` (Xan) | `7auwTLSv…` (`solana.turf.system`), `9gACbz…` |

Two facts are easy to get wrong, and both were written down wrong before.
**Xan `8K81…` was removed from BOTH Squads on 2026-09-15, then re-seated on
devnet only.** Devnet transaction #16 removed him at 09:41:25 MDT and mainnet
transaction #3 at 09:46:55 MDT. Devnet transaction #18 added him back at
14:02:10 MDT, in the same config transaction that added `2eGs8G3w…` and removed
`9gACbz…`; mainnet has no such transaction. So "removed from mainnet only" is
wrong as history, and "removed from both" is wrong as a description of today.
**Mason `CytJ…` really is absent from both.**

Devnet transaction #17, a proposal to add `7auwTLSv…`, still reads `Active` but
can never execute: #18 executed after it, and the multisig's stale transaction
index is 18. Do not approve it expecting a membership change.

⚠ **The hot system keys hold upgrade authority, against stated policy.**
`7auwTLSv…` is a full mask-`7` member here and simultaneously the key in
`turf-monster-mainnet`'s Heroku config that signs every entry and every payout;
`2eGs8G3w…` is the same on devnet. Every other doc in this ecosystem says these
keys are "deliberately excluded from Squads". The policy is right and the chain
does not implement it. Removing them is a Squads config transaction with Mr.
McRitchie's signature, tracked as its own task — not a doc edit, and not
something to quietly restate as satisfied.

What that buys the agent differs by cluster, and it is the whole reason step 1
of the ceremony reads differently on each:

| cluster | multisig | agent-reachable seats | ceremony |
|---|---|---|---|
| devnet | `7nRuVw3VZFC6z85tYVDitPnaUHZCkqLpJRSTBNtPmtZB` | **3 of 5** | **autonomous** — the agent reaches the threshold alone |
| mainnet | `4H3fP3otjMtupk1DQDjKXYY1dWjT6LNM4H4ZWZ1XcKSX` | **2 of 5** | **handoff** — one of Mr. McRitchie's keys supplies the third approval |

Key material is referenced by 1Password item name in the McRitchie Studio
credential inventory, never pasted here. Re-derive the numbers on the day —
this is a read, it signs nothing and spends nothing:

```bash
# Prints threshold, member count and each member's permission mask.
# @sqds/multisig resolves from turf-vault/node_modules.
node -e '
const m=require("@sqds/multisig"),{Connection,PublicKey}=require("@solana/web3.js");
const [rpc,pda]=process.argv.slice(1);
m.accounts.Multisig.fromAccountAddress(new Connection(rpc),new PublicKey(pda))
 .then(ms=>console.log("threshold",Number(ms.threshold),"of",ms.members.length,
   ms.members.map(x=>x.key.toBase58()+":"+Number(x.permissions.mask)).join(" ")));
' https://api.devnet.solana.com 7nRuVw3VZFC6z85tYVDitPnaUHZCkqLpJRSTBNtPmtZB
```

`turf-vault/scripts/squad-upgrade.js` asks the same question itself before it
spends anything, and refuses the run if the keys in hand cannot both approve and
execute — so the ceremony fails at the planner rather than halfway through, with
a paid-for buffer and no way to finish. **Funding is not the blocker.** Re-measured at `finalized` on 2026-09-15: the
mainnet fee payer `BLSBw8…` holds `3576585239` lamports (3.5766 SOL). An
**upgrade** needs a buffer sized `37 + 545928` bytes, which rents for
`2774152440` lamports (2.7742 SOL) — **refunded** when the upgrade completes,
so it is a float rather than a cost. That leaves **`802432799` lamports
(0.8024 SOL) spare.** Do not size this off the ProgramData account's own
balance: `BCuQEkMK…` holds 3.8009 SOL, which is rent already paid on a
545,973-byte account at the old 6,960 lamports/byte rate, not a figure anyone
has to raise. Query the minimum (`solana rent <bytes>`) rather than multiplying
by a constant — the cluster has been lowering the rate, and it read 5,080 on
2026-09-15.

> ⚠ **DO NOT PRICE THE BUFFER OFF THE ELF'S LOGICAL END. THIS IS A TRAP THAT
> HAS NOW CAUGHT TWO READERS.** Inside the 545,928-byte program region the
> ELF's logical content ends at `e_shoff + e_shnum * e_shentsize` =
> `544328 + 9 * 64` = **544,904**, and a trailing-zero scan reports **544,889**
> because the section header table's last 15 bytes are zero. Both are *logical
> ELF content*. **Neither is the deployed file.** The loader wrote all 545,928
> bytes and Agave reads the file through EOF, and the proof is the hash: only
> `sha256` over the full 545,928 bytes gives `e71a3fce…`, the `Program SHA256`
> row in `turf-vault/docs/CURRENT_DEPLOYMENT.md`. Sizing a buffer at
> `37 + 544889` yields `2768874320` lamports and **UNDER-FUNDS it by 1,039
> bytes**, which fails the ceremony after the buffer is paid for. The same
> distinction is worked through in `app/views/contract/show.html.erb` and
> pinned by `test/views/contract_measurements_test.rb`.

So the figure to watch is **capacity**: ProgramData carries 545,928 bytes of
executable room and the deployed v0.25 file is exactly 545,928 bytes — **zero
headroom**. A v0.26 even one byte larger needs `solana program extend` first,
and that rent is NOT refunded.
**In Rails, read the vault PDA from `Solana::Config.squads_vault_pda` — never as a literal.** It resolves `SOLANA_SQUADS_VAULT_PDA` first (via `.presence`, so an EMPTY value falls through rather than resolving to blank), then falls back to a NETWORK-keyed default (mainnet-beta -> `Bk9s…GdJm`, anything else -> `BW13…H6kC`), so a mainnet build cannot present a devnet authority by omission.

**Neither deployed app sets that variable — the key is ABSENT, not empty.** So the NETWORK-keyed default is the production path on both clusters, and the env var is a runbook escape hatch for pointing an app at a fresh Squad. `SOLANA_NETWORK` is therefore what actually selects the authority: `mainnet-beta` on `turf-monster-mainnet`, `devnet` on `turf-monster-qa` (both present and non-empty).

**Check it by KEY PRESENCE — never with `heroku config:get`.** `config:get` prints a bare newline for an absent key *and* for a present-but-empty one, so it cannot tell the two states apart. This doc used to cite it as the verification method, and that is how "absent" got written down as "length 0" in a review. Ask whether the key exists instead:

```bash
# absent -> false; present -> true (even when its value is the empty string)
heroku config --json --app turf-monster-mainnet | jq 'has("SOLANA_SQUADS_VAULT_PDA")'
heroku config --json --app turf-monster-qa      | jq 'has("SOLANA_SQUADS_VAULT_PDA")'

# independent second read: the table view lists every key BY NAME regardless of
# value, so zero matching lines means the key does not exist.
heroku config --app turf-monster-mainnet | grep -c SOLANA_SQUADS_VAULT_PDA
```

Re-verified 2026-09-05: absent on both apps, with `SOLANA_NETWORK` present and non-empty on both (`mainnet-beta` len 12, `devnet` len 6).

Three readers have carried this literal and been corrected. The view (`app/views/contract/_section_admin_state.html.erb`) showed the devnet Squad on `turf-monster-mainnet` — admin-shows-devnet-authority. Then `Admin::VaultInitController` and `solana:init_vault`, whose devnet fallback was not network-keyed; because the variable is absent, that fallback is what ran, so all three readers had the SAME live symptom — the devnet Squad on the mainnet app. The controller carried a second, LATENT defect in the same expression: `ENV.fetch` does not fall back for an empty value, so a single `heroku config:set SOLANA_SQUADS_VAULT_PDA=` would have turned the wrong address into a blank one. Both readers now route through `Solana::Config.squads_vault_pda` — vault-pda-readers-diverge. The guard in `test/integration/contract_upgrade_authority_test.rb` now bans both cluster literals from **every** `app/` and `lib/` source, not just views; `app/services/solana/config.rb` is the single exempted home for them.

Use `turf-vault/scripts/squad-upgrade.js` — it builds a buffer, sets the buffer authority to the Squad vault, then proposes + approves the upgrade tx through the Squad. Treat `turf-vault/docs/CURRENT_DEPLOYMENT.md` as the canonical program identity record; use the McRitchie Studio credential inventory for current 1Password item names instead of copying key refs into this app doc.

**Post-deploy IDL re-pin (mandatory)**: After every Squad upgrade, turf-monster MUST re-pin `EXPECTED_IDL_HASH` from the **freshly built** IDL — NOT `anchor idl fetch`. Squad upgrades run only the BPF `upgrade` instruction; they do NOT update the on-chain IDL account. `anchor idl fetch` therefore returns the stale pre-upgrade IDL.

```bash
# After deploying turf-vault, re-pin the IDL file of the CLUSTER YOU UPGRADED —
# and of the program VERSION you upgraded to. FOUR artifacts, cluster x version;
# cluster files differ only in `address`, and SOLANA_VAULT_GOVERNANCE picks the
# version half:
#   mainnet v0.25 -> config/turf_vault.mainnet.idl.json       (--features mainnet)
#   mainnet v0.26 -> config/turf_vault.mainnet.v026.idl.json  (--features mainnet)
#   devnet  v0.25 -> config/turf_vault.idl.json               (default build)
#   devnet  v0.26 -> config/turf_vault.v026.idl.json          (default build)
# lib/solana/idl_selection.rb owns that choice: Solana::Config applies it to ENV
# at boot, bin/deploy applies it to the TARGET app's config vars.
cp /Users/alex/projects/turf-vault/target/idl/turf_vault.json \
   /Users/alex/projects/turf-monster/config/turf_vault.mainnet.idl.json
cd /Users/alex/projects/turf-monster
jq -r .address config/turf_vault.mainnet.idl.json   # must be that cluster's program ID
shasum -a 256 config/turf_vault.mainnet.idl.json    # → the new EXPECTED_IDL_HASH

# Commit, then deploy. bin/deploy asks that same rule which file the TARGET boots
# against — SOLANA_NETWORK *and* SOLANA_VAULT_GOVERNANCE — widens
# EXPECTED_IDL_HASH to {old,new}, pushes, then tightens to the hashes this slug
# ships for that cluster: both switch positions, so a `heroku config:unset
# SOLANA_VAULT_GOVERNANCE` rollback still boots. No manual heroku config:set.
git add config/turf_vault.mainnet.idl.json
git commit -m "Re-pin IDL after turf-vault vX.Y.Z deploy"
bin/deploy
```

`Solana::Config.verify_idl!` will refuse to boot — and to precompile assets — in production when the file's SHA256 ≠ `EXPECTED_IDL_HASH`. Running prod against a drifted IDL silently corrupts every Borsh decode.

**Also refresh the `/contract` page — after every mainnet upgrade.** `app/views/contract/show.html.erb` (the public `/contract` transparency page) hand-maintains figures a new binary changes. Its version pill, cluster pill, and instruction and error counts read the committed IDL and `NETWORK`, so they track the re-pin; the figures below do not. `test/views/contract_measurements_test.rb` pins the page's `measured` record to `config/turf_vault.mainnet.idl.json` by version **and** sha256, so re-pinning that file turns it red until you redo step 1.

1. **Binary, ELF sections, rent — from the deployed program, not a local build.** Anchor builds are not byte-reproducible, so measure the bytes that are executing. Public RPC, no credential:

   ```bash
   RPC=https://api.mainnet-beta.solana.com
   solana program show DaFv83yokwTz8msP9CzJ13eazSGk15NuUTxjkfzJzxMM --url $RPC   # ProgramData address, data length
   solana program dump DaFv83yokwTz8msP9CzJ13eazSGk15NuUTxjkfzJzxMM mainnet.so --url $RPC
   shasum -a 256 mainnet.so           # program_sha256; must equal turf-vault docs/CURRENT_DEPLOYMENT.md
   LLVM=~/.cache/solana/v1.52/platform-tools/llvm/bin   # any platform-tools version with llvm-objdump
   $LLVM/llvm-objdump --section-headers mainnet.so      # section bytes
   $LLVM/llvm-readelf --file-header mainnet.so          # ELF length = e_shoff + e_shnum * 64
   # Space and lamports of the ProgramData and Program accounts, with the slot read at:
   curl -s $RPC -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,
     "method":"getMultipleAccounts","params":[["<program id>","<ProgramData address>"],
     {"encoding":"base64","commitment":"finalized","dataSlice":{"offset":0,"length":0}}]}'
   # TODAY's rent-exempt minimums — QUERY them, one call per size. Never multiply
   # by a per-byte constant: the cluster has been lowering the rate (6,960 when
   # this program was funded, 6,333 on 2026-09-11, 5,080 on 2026-09-13).
   solana rent 545973 --url $RPC   # ProgramData: 45-byte header + the deployed file
   solana rent 545965 --url $RPC   # a deploy buffer: 37-byte header + the deployed file
   solana rent 36     --url $RPC   # the Program account
   ```

   **The deployed file is the whole program region** — `solana program dump` writes it, the loader wrote it, and Agave reads it through EOF — so it is what `deployed_file_bytes` holds and what sizes both the ProgramData account (`+ 45`) and a deploy buffer (`+ 37`). The ELF's logical content usually ends earlier, with zeros after it; that endpoint goes in `elf_content_bytes` and is printed only where the page labels it as ELF content. **Keep balances and minimums apart**: `programdata_balance` / `program_acct_balance` are what the live accounts HOLD (`getMultipleAccounts`), while `pd_rent_min` / `buffer_rent_min` / `program_acct_min` are what they would COST at that slot (`solana rent`). Then update `measured` (version, slot, date, `idl_sha256` of the re-pinned mainnet IDL, `program_sha256`).
2. **Per-instruction bytes and `.text` buckets — from a debug-info rebuild** of the deployed tag with `--features mainnet` (`CARGO_PROFILE_RELEASE_DEBUG=2 … cargo-build-sbf` → `llvm-objdump --syms | rustfilt`, dedup by address, bucket by instruction module): the deployed binary is stripped, so it cannot attribute them. Update `attributed_on` when you do. Until then the page labels them with the build they came from (`v0.19` as of 2026-09-10).
3. **Auth roles and Rails call sites** — re-audit the admin playbook's web2/web3 caller map. The playbook names any committed-IDL instruction it does not cover yet.

### The authorities console — `/admin/authorities`

**One page that reads all three authorities off the chain, and the only place a
compromised `VaultState` signer can be evicted.** Built for a specific threat
model: the WALLET is compromised, not the infrastructure — the Rails app, the
deploy pipeline and Mr. McRitchie's own machine are trustworthy and only the keys
are not. Under that model an in-app page is the right shape, because the server
is the part you can still believe. (The other scenario — the system itself
captured — is a separate standalone offline console.)

**PAUSE IS NOT A REMEDY, and the page says so.** Verified across all 23
instruction sources on turf-vault `accepted`: exactly two read `vault.paused` as a
gate — `enter_contest` (`:147`) and `enter_contest_with_token` (`:115`).
`mint_entry_token`, `grant_seeds`, `create_contest` and the username instructions
do not mention the flag at all. So a paused vault still MINTS ENTRY TOKENS and
GRANTS SEEDS: the value-creating paths a key thief would use. Pausing stops paying
customers from entering and does not inconvenience the thief. Re-derive it with
`grep -rn 'paused' programs/turf_vault/src/instructions/`.

**Why it reads rather than quotes.** When it was built, three places in this repo
stated the Squads upgrade multisig's membership and threshold and all three
disagreed — `Solana::Config` said "FOUR at threshold 3", the admin hub tile said
"2-of-3", and this file's own figure predated the two config ceremonies. The
measured answer, the per-cluster split, and the hot-key warning are stated ONCE,
under **Program Upgrades — Squads multisig** above; they are not repeated here,
because a second copy of a number is how this section came to disagree with
itself in the first place. What matters for this page is the consequence: a page
an operator opens mid-incident cannot inherit a figure somebody wrote down.
`Solana::Squads` decodes the account; `Solana::Squads.vault_pda` DERIVES
`[b"multisig", <multisig>, b"vault", 0]` under the Squads program, so the match
against the program's upgrade authority is proven rather than asserted.

| Panel | Source | Written by |
|---|---|---|
| Vault signer set | `VaultState.signers` ++ `signers_ext`, all five slots | `update_signers` — **this page** |
| Per-action thresholds | the `GovernanceConfig` PDA, or "not on chain" | `set_action_threshold` |
| Program upgrade authority | the Squads V4 multisig account | Squads' own web UI — **link out** |
| Server signing identity | `Solana::Keypair.admin` | nothing on chain |

**Squads is deliberately out of scope for the ACTION** — because Squads already
ships a web UI for membership, and a second, less-tested path to the same account
would be a liability. That reason holds unconditionally.

**Whether a stolen key can EXECUTE there is computed, never assumed.** The page
intersects the Squads *voting* seats with the live vault signer set and compares
that count against the Squads threshold, in four states — unread, none, below,
and at-or-above. The at-or-above branch says plainly that a holder could execute
a program upgrade and that evicting them from the vault does not touch it. An
earlier draft of both the page and this paragraph ended "so anyone short of that
can never carry one out", which was true of the numbers in front of it and is
**not a general fact**: the intended five-member vault set and the mainnet Squad
membership now name the same wallets, so the overlap can reach the threshold.
Only a voting seat counts, because a mask-1 member can approve nothing.

The link is `Solana::Config.squads_app_url`, which is cluster-keyed:
**`devnet.squads.so` is decommissioned**, so there is no cluster-flavoured host to
switch to — `app.squads.so` serves both and the cluster is carried by the ADDRESS
in the URL.

#### Evicting a signer

Two steps, and the split is the design. **Arm** records the proposed set and
builds nothing, so the operator reads the exact new signer set with no clock
running. **Co-sign** mints fresh bytes at CLICK time, collects the signatures and
broadcasts. Building at arm time would hand him bytes whose blockhash dies within
~90 seconds of him starting to read — the defect that left $140 of payouts unsent
on the treasury queue for three months.

**A fresh blockhash, never the durable nonce.** A nonce-anchored transaction is
only recognised when `advanceNonceAccount` is instruction 0, and Phantom injects
its own Lighthouse guard instructions ahead of whatever was built. That makes the
nonce unusable for ANY Phantom-signed flow rather than merely undesirable (the
2026-06-11 finding recorded on `Vault#simulate_and_broadcast`). No cosign builder
passes `durable_nonce:`; the only non-nil call site in `vault.rb` is
`build_create_contest`'s server-signed branch.

**A WALLET THAT SIGNS CANNOT BE EVICTED BY THE TRANSACTION IT SIGNS.** Continuity
requires `threshold` of the keys that authorized a rotation to survive it, and at
three signatures against a threshold of three that means all of them. Every other
builder in `vault.rb` signs locally as `Keypair.admin`, which would make the
SERVER an authorizer of every rotation — and therefore make the server's own vault
key the one key that could never be removed. That is the key most likely to be
stolen: it sits in Heroku config on a running dyno and signs every entry and
payout. So `Vault#build_update_signers` takes a `lead_signer:` and picks its build:

- **server leads** → `build_partial_signed`, the ordinary shape; account 0 is
  filled at build time and the operator supplies the rest.
- **operator leads** → `build_partial_unsigned`; NOTHING is pre-signed, account 0
  is reserved for one of his wallets which pays the network fee, and every
  signature is collected in Phantom. **This is the only shape that can evict the
  server's key.**

**The shapes the two live programs accept are different, and the chain decides.**
`Admin::AuthoritiesController#vault_shape!` refuses to build when
`SOLANA_VAULT_GOVERNANCE` disagrees with whether the `GovernanceConfig` PDA
exists, in both directions.

| | deployed v0.25 (devnet + mainnet today) | v0.26 (turf-vault `accepted`) |
|---|---|---|
| argument | `[Pubkey; 3]` | `[Pubkey; 5]`, left-packed |
| signatures | exactly 2 (`validate_multisig`) | `UPDATE_SIGNERS`, default 3, **floor 3** |
| empty slots | refused outright (6017) | allowed as a SUFFIX only |
| reduced set | **not expressible** | yes — this is what the page is for |

`Solana::SignerRotation` mirrors both guard sets **in the program's own order**,
because Anchor returns the FIRST failing constraint and stops: a validator that
checked them in a different order would name a different problem than the chain
would. Every refusal carries the program's error code.

| refusal | code | when |
|---|---|---|
| `Unauthorized` | 6000 | an authorizer is not in the on-chain set |
| `DuplicateSigner` | 6014 | a key repeats, in the set or among the authorizers |
| `SignerContinuityRequired` | 6017 | too few authorizers survive; or (v0.25) any zeroed slot |
| `InsufficientSigners` | 6046 | fewer signatures named than the threshold |
| `SignerSetTooSmall` | 6052 | a gap; or below `required` / `max_live_threshold` / above 5 |

**The signature is stamped before verification, and the row is claimed before
the wire goes out.** Both broadcast paths — `Admin::AuthoritiesController` and
the treasury's `Admin::PendingTransactionsController` — share one rule, on the
model, because the rule decides whether money can move twice:

| step | method | why |
|---|---|---|
| derive | `Solana::Vault#signature_for_wire` | the signature is the first 64 bytes of the signed wire, so the server knows it BEFORE it sends and never needs the RPC's reply to record it |
| claim + stamp | `PendingTransaction#claim_for_broadcast!` | `pending?` is a READ; two requests both pass it and both broadcast. ONE conditional UPDATE takes the claim and writes the signature and `broadcast_at` together, so a claimed row always names its transaction. Not `with_lock` — see below |
| rewind | `PendingTransaction#rewind_broadcast!` | ONLY on `Solana::Vault::PreflightRejected` (the simulation refused, so the send was never made) or on a verdict from the CHAIN. Guarded on the exact signature proven dead |
| reconcile | `PendingTransaction#reconcile_broadcast!` | asks `getSignatureStatuses` and applies the four-way verdict (`OnchainSendVerdict#send_verdict`): `:landed` / `:failed` / `:never_landed` / `:ambiguous`. The only path that can clear a transaction which landed and FAILED, because `TxVerifier` refuses anything carrying `meta.err` |

The treasury path used to stamp the signature **after** `TxVerifier.verify!`
(one RPC call per claimed signer), so a transaction that LANDED and then met an
RPC hiccup was left `pending`, unsigned and re-broadcastable — the money moved
and the record said it had not. That was
`/tasks/broadcast-records-signature-late`. The general rule, shared with
`Cdp::OfframpSendJob`: **never let a verification step decide whether a
broadcast happened — the broadcast happened when the wire went out.**

**Why `with_lock` is not the claim.** Not because it ties up a pooled
connection — the connection is checked out for the request either way. Because
it opens a **transaction** and takes a **row lock**, then holds both across the
RPC round trips inside the block: the simulation, the send, and a confirmation
poll allowed to run 30 seconds before it gives up. A second request for the same
row would BLOCK for the whole of the first one's work and only then learn it had
lost. One conditional UPDATE gets the identical exclusion and fails the loser
immediately.

**Why the signature is stamped BEFORE the send, not the instant it returns.**
Any stamp taken from the RPC's reply leaves a claimed row with no signature
whenever that reply is lost — and every door then shuts: `#rebuild` and
`#broadcast` refuse a non-`pending` row, `#confirm` needs a signature that does
not exist, and `Admin::AuthoritiesController#cancel` refuses to discard what may
be on chain. That is the **likely** case, not a rare one: `simulate_and_broadcast`
simulates with `sig_verify: false` and `replace_recent_blockhash: true`, so the
node's own pre-flight on the send is the first check of the real blockhash and
the real signatures, and it refuses without forwarding. Deriving the signature
from the bytes removes the state entirely.

**Why no exception from the send is treated as a proof.** `Solana::Client#call`
retries `Net::ReadTimeout` and `Errno::ECONNRESET` — the faults that mean the
request was written and the answer was lost — and re-POSTs the same wire,
surfacing only the LAST exception. So a coded `RpcError` (`Blockhash not found`,
say) can be the answer to a second attempt whose first attempt already forwarded
the transaction, and a blockhash can die inside the 30-second read timeout that
produced the first fault. The caller cannot see that history. The chain is the
only witness, which is what `#reconcile_broadcast!` asks.

**Both broadcast controllers build their `Solana::Vault` above the claim.** Its
constructor validates the RPC URL and decodes keypairs, so it can raise
`InsecureRpcUrlError` or a base58 error — neither of which is
`PreflightRejected`, and so neither would give a claim back. Hoisting it takes
the whole class of constructor failures out of the claimed window.

On the authorities surface the consequence is worse than a double payout: a
second attempt after the first landed is authorized by keys the first one just
evicted, fails `Unauthorized`, and reads to the operator like his eviction did
not work. A row left `submitted` is the safe failure.

`#confirm` is the one path that still proves before it records, on both
surfaces, and deliberately: there the signature is an unverified CLIENT claim,
not one this server produced.


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

**Write ordering (changed 2026-09-05, PR #551 — the old text here said the opposite):** the DB row is written **BEFORE** the broadcast, not after. The row is saved `status: :pending` carrying the slug-derived PDA, the money then moves, and the row is promoted to `open` only once the transaction is verified.

The reason is which failure you would rather have. Broadcasting first meant any raise between the broadcast and the insert — an RPC read-back, an S3 banner upload, a NOT NULL column — left the creator's prize pool in the vault with **no Rails row at all**, and `Entries::OnchainReconciler` is rooted in Contest rows, so that state was not merely unreconciled but unreachable. Writing first inverts it: a crash leaves a **row with no money**, which is sweepable. So the database no longer "always reflects committed on-chain state" — a `pending` row means *written, not yet verified*, and that is the point.

1. Admin fills form + submits → `POST /contests` (`ContestsController#create`)
   - Click-time prechecks: on-chain `Contest` PDA must not exist; creator's USDC must cover the prize pool. Insufficient-USDC modal includes a "Mint $500 Test USDC" recovery button.
   - Server builds a fully unsigned `create_contest` TX with both required signature slots reserved (admin payer + creator). Returns the unsigned TX + a signed `params_token`.
2. Client: `phantom.signTransaction(tx)` only. The browser serializes the Phantom-signed wire with the admin slot still empty and posts it back; it does not simulate, broadcast, or poll.
3. `POST /contests/finalize` (`ContestsController#finalize`) — collection route, no `:id`.
   - `Vault#create_contest_expectation` rebuilds the create_contest instruction from the server's own draft (fee schedule, payouts, prize pool, lock timestamp, slug-derived PDA), and `Solana::Cosign::Expectation` judges the signed wire against it — same accounts in the same order, same data — before the admin key signs anything.
   - **Step 1 — the write-ahead row.** Saves the Contest as `status: :pending` with the derived PDA and `skip_onchain_callback = true`, before a single lamport moves. The flag (plus `onchain?` being true once the PDA is set, plus `create_onchain!`'s own `return if onchain?`) is what stops the legacy `Contest#create_onchain!` after_create callback from broadcasting a SECOND, house-funded `create_contest`. Saving here also moves the column-level failures ahead of the money.
   - **Step 2 — the broadcast.** Rails admin-cosigns, simulates, broadcasts, waits for confirmation. Past this line the money is real.
   - **Step 3 — stamp the signature immediately**, before any read-back that can raise. The row stays `pending`: a broadcast is not a verification.
   - **Step 4 — verify** via `verify_solana_transaction!` (OPSEC-010 — matches the `create_contest` discriminator + expected accounts).
   - **Step 5 — promote** the row to `open`.
   - **Step 6 — attach the banner** last, logged and never raised: an S3 upload of a user-supplied file is the widest failure window in the method and the least worth losing a contest over.

### Sweeping a stranded `pending` contest

A crash anywhere in steps 1-5 leaves a `pending` row behind. `Contests::PendingReconciler` (service + `PendingContestReconcilerJob`, every 15 minutes in `config/schedule.yml`) resolves them, **read-only on chain** — it never signs, broadcasts or transfers:

| On-chain read of the derived Contest PDA | Verdict |
|---|---|
| Account **present** | **Promote** to `open`. `create_contest` `init`s the Contest PDA, `init`s the prize-pool token account and CPIs the creator's USDC transfer in ONE atomic instruction, so the account existing **is** the funding proof. |
| Account **absent** | **Delete** the row. No broadcast landed, so no money moved, and the row is only squatting on a uniquely-indexed slug its creator cannot reuse. |
| RPC **fault** | **Leave it.** An unreadable chain is not evidence of absence — folding the error into "absent" would let a rate limit delete a funded contest. |
| PDA does not match the slug, or the row carries a broadcast signature, or entries/messages/a landing page reference it | **Flag** (`onchain_reconcile_flagged_at` + `ErrorLog`) and never touch it again. A human reads the chain. |

Rows younger than `RECONCILE_AFTER` (10 minutes) are never touched — an in-flight finalize is indistinguishable from a strand by inspection.

**Do not gate the promote on a positive prize pool.** `create_contest` validation #5 accepts `any_fee_set || prize_pool > 0`, so a fee-charging contest with a zero prize pool is legal on chain; requiring a positive pool would delete a real, funded contest.

Until the sweep runs, a retry of the same slug is refused by the DB guard rather than by the chain, and the error message says so — including that no payment was taken and that it clears itself.

### Legacy server-only fallback

`Contest#create_onchain!` (via `after_create`) is preserved for Rails console / scripts / tests (`Rails.env.test?` auto-skips). The old `POST /contests/:id/prepare_onchain_contest` + `confirm_onchain_contest` endpoints still exist for backward compat and are referenced by `e2e/onchain.spec.js` — the production UI no longer uses them.

## Onchain Entry — three payment rails, one confirm gate

All three end at `Entry#confirm!` / `#confirm_onchain!`, which enforce the payment-proof (`tx_signature`), lock-time, exactly-`picks_required`, no-locked-games, per-user-limit, and sybil checks.

1. **Managed-wallet token-consume** — managed user with an `EntryTokenAccount`: `Vault#enter_contest_with_token` signs with the server-held keypair; consumes the token (no USDC moves), awards seeds, then `bust_entry_tokens_cache!`.
2. **Managed-wallet USDC** — `Vault#enter_contest` signs **both** the admin (payer) and user (server-managed keypair) slots and broadcasts directly. SPL transfer user-ATA → `op_rev` ATA. There is no DB-balance or PDA-balance deduction — neither exists in v0.16.
3. **Phantom-direct** — Phantom-FIRST (2026-06-06): `prepare_entry` selects an unconsumed token owned by `web3_solana_address` first and builds `enter_contest_with_token`; otherwise it builds the currency-funded `enter_contest`. Both wires are fully unsigned (admin reserved as fee-payer + nonce-authority but NOT signed) and the server records the funding choice plus token PDA on a `PendingTransaction`. Phantom signs first; the client POSTs the signed wire bytes to `confirm_onchain_entry`, which admits only the recorded instruction/funding pair, admin-cosigns (`Vault#cosign_and_broadcast_entry` via `Solana::Transaction.cosign_wire`), runs a `simulateTransaction` pre-flight, broadcasts **server-side**, then verifies (`TxVerifier`) and runs `Entry#confirm_onchain!`. If Phantom dismisses or invalidates the unsigned request, `discard_prepared_entry` safely expires only that user's signatureless PT and a user-tapped **Try Again** refreshes session state before `prepare_entry` builds fresh wire bytes; no page reload is required. Signed PTs are never discarded because they may have been broadcast. `recover_pending_entry` resolves those signed entries stranded by a mid-flight refresh (also TxVerifier-gated — Lazarus audit #1) and invalidates spent-token caches on both full verification and the already-active shortcut.

**Currency selection (2026-06-10)**: `prepare_entry` takes a strict `currency=usdc|usdt` param (default `usdc`). USDT is rejected unless the contest's `accepts_usdt` flag is set — only contests whose on-chain `entry_fee_by_currency` slot 1 was funded at creation accept it, and that array is **immutable** after `create_contest`, so contests created before 2026-06-11 stay USDC-only forever (the program rejects `currency_idx: 1` with `EntryFeeNotSet` 6027). The endpoint ensures the user's ATA for the SELECTED mint and threads `currency_idx` (0=USDC, 1=USDT) into `build_enter_contest` + the `PendingTransaction` metadata. Client: `#board-config` carries `acceptsUsdt`, the flow auto-picks USDC-first/USDT-fallback, and `eligibilityBlocker(session, neededCents, { acceptsUsdt })` only counts USDT funds on accepts-USDT contests.

(There is one unified `enter_contest` instruction — the old `enter_contest_direct` was removed in v0.16. Phantom users' navbar balance decreases live after the transfer; no DB balance is tracked for any wallet type.)

## Seeds System (On-Chain)

Seeds are awarded on-chain per the active **Season**'s `seed_schedule` (turf-vault v0.11.0+). Default schedule is `[25, 19, 14, 10, 7]` — entry index 0 → 25 seeds, index 4+ clamps to slot 4. No DB column for the seeds count — read from the `UserAccount` PDA via `Solana::Vault#sync_balance`. UI-derived levels: `level = seeds / 100 + 1` (`SEEDS_PER_LEVEL = 100`); class methods `User.level_for(seeds)`, `seeds_toward_next_level(seeds)`, `seeds_progress_percent(seeds)`. The active season is tracked in `SeasonConfig.current_season_id` (Rails singleton); the on-chain `Season` PDA lives at `[b"season", season_id_le]`. Compute an entry's award via `Solana::Vault.new.seeds_for_entry(entry_num)`. Progress-bar partial `_seeds_bar.html.erb` (navbar via `_user_nav` + contest show via `_slate_progress_xp`); level-up confetti; "Free Entry Earned 🎟️" badge in the entry-confirm modal. The level-up token is **minted automatically**: a trusted fresh seed snapshot calls `LevelUpTokenMintJob.nudge`, which updates the denormalized mirror and immediately enqueues a targeted run. The target re-reads live chain truth through `Tokens::LevelUpGrant` before minting, and the client polls the canonical session hydrate with bounded backoff so the token badge appears without a reload. The every-15-minute `LevelUpTokenMintJob` cron in `config/schedule.yml` remains a recovery sweep for missed enqueues and RPC outages. Both paths mint one `EntryTokenAccount` per milestone under the **deterministic** `source_ref` `levelup:<deployment>:<wallet-hash>:<level>` (the deployment is `qa` or the Rails env; the wallet hash is the first 16 hex of `sha256(address)`, kept short because `padded_source_ref` raises past 64 bytes). Because the PDA is `sha256(source_ref)` and the program `init`s it, a repeat mint collides on-chain — so retries and overlapping runs cannot double-grant, and the chain itself is the ledger of which levels are paid. **The wallet and the deployment are both in the ref because neither is in the PDA seeds**: `entry_token_pda` derives from `sha256(source_ref)` under the program id alone, and `SOLANA_PROGRAM_ID` defaults to the SAME devnet program for development, test and QA — so a ref keyed only on `users.id` made QA user 7 and a local dev user 7 collide on one account, where the loser's mint fails forever. The PDAs outlive the database, so a QA reset reproduces it wholesale. The sweep's candidate query is pure SQL against the denormalized mirror, so an idle run issues **zero** Solana RPCs: the partial index `index_users_on_pending_level_up_grants` carries the predicate `level > entry_tokens_granted_level` and is keyed `(entry_tokens_swept_at, id)` — the sweep's own `ORDER BY` — so the batch is read straight off it in rotation order. `entry_tokens_swept_at` is stamped on **every** pass (minted, nothing owed, unevaluable, or raised) purely to send a just-visited row to the back of the queue; it is never a record of payment, which remains `entry_tokens_granted_level` and advances only on proof. Rotation is what stops a permanently stuck row from occupying the batch and starving every user behind it. A user the sweep cannot evaluate — no `UserAccount` PDA at their address, so on-chain seeds cannot be read — is reported with a named log line **and** an `ErrorLog`, never skipped silently. The mint count is clamped to the same `owed` figure `/admin/free_entries` computes (`seeds / 100 - tokens.length`), so it never pays over an operator's manual mint — that page remains the manual backstop, its arithmetic unchanged. `User#level` is persisted by `update_level_from_seeds!` from trusted server-side chain reads.

The per-season schedule above is authoritative for Turf Monster; update this doc and the active `SeasonConfig`/vault setup together when changing rewards.

## Rake Tasks (`lib/tasks/solana.rake`)

- `solana:init_vault` — initialize the vault on devnet. Args `INIT=true SIGNERS=addr1,addr2,addr3 THRESHOLD=2` (optional `TREASURY=<squads_vault_pda>`, otherwise `Solana::Config.squads_vault_pda` — `SOLANA_SQUADS_VAULT_PDA`, then the NETWORK-keyed cluster default; it is never a fixed literal, because `treasury_authority` is PINNED at initialize time and a devnet Squad pinned on mainnet cannot be swept to). OPSEC-013-gated in production. There is no `force_close` arg — the `force_close_vault` instruction was removed in v0.16; teardown = redeploy the program.
- `solana:health` — pre-flight before any cluster flip: genesis-hash match + program-exists-on-RPC + IDL-hash match. Exits non-zero on mismatch. **A check that could not RUN is reported as such, never as a tick** — the program-exists step reads `Solana::Vault.ensure_program_id_live!`'s tri-state return (`:live` / `:cached` / `:unverified`) rather than inferring a pass from the absence of a raise. That guard fails OPEN on purpose (`TokenPurchaseJob` depends on it), so against a rejecting endpoint the task used to print `✓ PROGRAM_ID exists on RPC` one line below `getGenesisHash failed`. It also passes `force: true`, so a ≤5-minute cache entry cannot answer for the CURRENT endpoint, and it builds its `Solana::Client` inside a rescue so a fat-fingered endpoint is diagnosed instead of raising past every check.
- `solana:idl_hash` — print the committed IDL's SHA256 (the value for `EXPECTED_IDL_HASH`).
- `solana:verify_idl` — run `verify_idl!` against the committed IDL.
- `solana:airdrop` — airdrop SOL to admin.
- `solana:check_balance` / `solana:check_admin_balance` — read on-chain SOL/USDC balances.
- `solana:mint_usdc` — mint test USDC to the admin ATA (`AMOUNT=<dollars>`, default 100). **Devnet only — hard-aborts on live production (OPSEC-020).** QA apps are exempt: they boot as Rails production but set `QA_ENV=true`, so `AppFlags.live_production?` reads false there and the devnet tooling stays usable.
- `solana:fund_wallets` — fund a set of wallets (dev bring-up).
- `solana:generate_keypair` / `solana:test_encryption` — managed-wallet key tooling.
- `solana:reencrypt_managed_wallets` — re-seals every managed-wallet row under the current `MANAGED_WALLET_ENCRYPTION_KEY`, verifying each under that key ALONE before writing it. `DRY_RUN=1` writes nothing. Exit 0 only when every row verifies, 1 when any row does not, 2 when the configuration is refused. See [Rotating the managed-wallet key](#rotating-the-managed-wallet-key-managed_wallet_encryption_key).
- `solana:verify_managed_wallet_keys` — read-only count of the rows that open under the current key alone. Exit 0 only when all of them do.
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
UNAUTHENTICATED and additionally renders the value as visible page text. Five of
the six are still guarded by
`test/integration/rpc_credential_not_in_browser_test.rb`; the sixth stopped
existing when `layouts/modal_preview` was deleted on 2026-09-09. On
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

## Rotating the managed-wallet key (`MANAGED_WALLET_ENCRYPTION_KEY`)

Every managed wallet's Ed25519 secret sits in `users.encrypted_web2_solana_private_key`,
sealed under a key derived from `MANAGED_WALLET_ENCRYPTION_KEY`. The procedure lives
in the hub: `mcritchie-studio/docs/agents/agents/steffon/sops/credential-rotation.md`
(Phase 2). This section is the code it drives.

**Deploy before rotate.** Everything below exists only on a release that carries
`managed-wallet-key-rotation`. Merged is not deployed. On an older release the
first config write strands every managed wallet, and the old task reports
success. The SOP's Gate 0 proves the running release has the code before
anything is minted.

**Why it was unsafe before `managed-wallet-key-rotation`.** `Solana::Keypair` read
one key and nothing else, and `solana:reencrypt_managed_wallets` decided a row was
done by its `v2:` prefix. The prefix names the scheme, not the key. After a key
swap every row still read `v2:`, so the task skipped them all, printed
`0 migrated, N already v2, 0 failed`, and exited 0 — while every managed wallet
had become undecryptable.

**The two-key window.**

| Env var | Seals | Opens |
|---|---|---|
| `MANAGED_WALLET_ENCRYPTION_KEY` | every new ciphertext | yes, tried first |
| `MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS` | never | yes, only while set |

A `v2:` payload is opened by trial: current key, then previous. That is safe
because the scheme is authenticated (AES-256-GCM under `load_defaults 8.1`): a
wrong key raises `InvalidMessage` rather than returning bytes. No key identifier
is stamped into the ciphertext. The defect was a label trusted as proof of a
key, so the only proof accepted now is opening the row with the key.

**The migration**, per row (`Solana::ManagedWalletRotation`):

1. If the current key ALONE opens it and the secret derives the stored
   `web2_solana_address`, it is already new. Nothing is written.
2. Otherwise it is opened with the previous key (or the legacy scheme, for an
   untagged row), and it must derive the stored address.
3. `DRY_RUN=1` stops here and counts it as would-migrate.
4. The exact plaintext is re-sealed under the current key and read back under
   the current key alone, then compared byte for byte in memory. Nothing is
   logged.
5. The row is written by compare-and-swap, so a row that changed during the
   run is never clobbered.

Each row is its own atomic write. A run that dies halfway leaves every row
whole — old or new — and both keys still open both. Re-running finishes the job.
After the walk, an independent recount opens every row under the current key
alone. The run exits 0 only when that recount is complete.

The last line of a run is the verdict. The counts above it are the evidence:
`total / migrated / already-new / failed` and `Read-back: N of M`.

**Refusals (exit 2, nothing read or written)**, when `…_PREVIOUS` is set:

- the new key is absent;
- the new key is not 64 hex characters (what `SecureRandom.hex(32)` mints);
- the new key equals the previous one, even ignoring case or whitespace;
- `…_PREVIOUS` is set but empty (what an empty `$OLD` writes).

With no `…_PREVIOUS` set, the task is the OPSEC-015 legacy→v2 migration. Every v2
row must already open under the current key, or it FAILS. It never reads a swapped
key as "already v2" again.

**What rotation does NOT do.** It re-seals the envelope; it never changes a
wallet's private key. Every ciphertext sealed under the OLD key — in Postgres
backups, forks, followers, or a dump — stays openable by the old key forever. If
the old key is compromised, rotating protects nothing an attacker already copied.
That is an incident: move funds to fresh wallets and destroy the old backups.

Guards: `test/tasks/solana_managed_wallet_key_rotation_test.rb` (the regression
and every path above, driven through the rake task and graded by exit status),
`test/services/solana/keypair_rotation_test.rb`,
`test/services/solana/managed_wallet_rotation_test.rb`.

## Solana Auth Security

- **SIWS / nonce replay prevention**: Solana sign-in nonces include a timestamp with an enforced 5-minute expiry; the nonce is deleted from the session before verification (delete-before-verify) to prevent replay. Signature verification is host-bound (`Solana::AuthVerifier`, OPSEC-018).
- **TX verification**: `Solana::TxVerifier` binds a submitted signature to the expected instruction + signer + server-re-derived PDA before any DB state is credited (OPSEC-010).

## Error namespace

turf-vault custom errors start at **6000** (`errors.rs`). Anchor framework **3000-range** errors (e.g. 3012 `AccountDidNotDeserialize`) signal **schema drift** between the deployed program and an on-chain account — i.e. an IDL/layout mismatch — **not** a vault error. Key codes: `ContestNotOpen` 6003, `ContestAlreadySettled` 6006, `SettlementOverflow` 6008, `ContestNotCancellable` 6029, `ContestLocked` 6034, `ContestConcluded` 6035. Several codes (6011/6012/6017/6019/6028) are retired-but-kept for numbering stability.

<!-- citation-guard: external (2 citations) — both name turf-vault Rust instruction sources, which this repository does not contain; no line number written here can be checked from turf-monster -->
