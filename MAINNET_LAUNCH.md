# Turf Monster Mainnet Launch Runbook

> **HISTORICAL FIRST-LAUNCH RUNBOOK.** Turf Monster's current production app is
> `turf-monster-mainnet` at `https://app.turfmonster.media`, and normal deploys
> go through `bin/deploy`. Do not use this file as current deployment identity
> without first reconciling it against `docs/SOLANA.md`,
> `docs/LOCAL_STACK.md`, and `turf-vault/docs/CURRENT_DEPLOYMENT.md`.

One-time runbook for the **v0.15.0 mainnet first deploy**. Read top-to-bottom; each step has acceptance criteria. For ongoing post-launch deploys, use `bin/deploy`.

> **Audit baseline**: this runbook assumes you've already shipped the v0.15.0 hardening (H1 init constraints, M5 pause/unpause, $100/24h withdraw cap, H4 IDL boot-refusal, H2 payout_entry removal). See `/Users/alex/projects/turf-vault/CHANGELOG.md` for the full v0.15.0 changeset.

---

## 0. Pre-flight (do all of this BEFORE touching mainnet)

- [ ] **Devnet smoke test**. Latest v0.15.0 builds + works end-to-end on devnet. Test: deposit, enter, settle (via cosign), withdraw, pause, unpause, $100 cap.
- [ ] **Wallets funded**:
  - [ ] Xan mainnet wallet: ≥ 5 SOL (program deploy + initial Season + sundry)
  - [ ] `solana.turf.system` (`7auwTLSv…`) mainnet wallet: **0 SOL at 09:12 on 2026-09-15, funded at 09:20 the SAME MORNING — eight minutes later, not "that afternoon".** Re-measured at `finalized` on 2026-09-15: `1000000000` lamports (1.0000 SOL). Read the balance rather than any number written here. This is the key `SOLANA_ADMIN_KEY` is moving to on `turf-monster-mainnet`; repointing an underfunded fee payer breaks production settlement, so the cutover task owns the call on whether the balance is *sufficient for sustained fee payment*, not merely non-zero.
  - [ ] Alex Phantom mainnet wallet: ≥ 0.05 SOL (will sign initialize once)
  - [ ] Mason mainnet wallet: ≥ 0.05 SOL (will Squads-cosign deploys + treasury ops)
- [x] **Squads V4 multisig exists on mainnet — and its membership was rotated on 2026-09-15.** Each cluster reads **threshold 3 of FIVE members**, every member mask 7 (Initiate|Vote|Execute). Re-measured on-chain at `finalized` on 2026-09-15 from multisig `4H3fP3otjMtupk1DQDjKXYY1dWjT6LNM4H4ZWZ1XcKSX` (mainnet) and `7nRuVw3VZFC6z85tYVDitPnaUHZCkqLpJRSTBNtPmtZB` (devnet), through two independent RPC providers and a raw-byte check of the member offsets. **The clusters do NOT carry the same five** — read the one you mean:

  | seat | devnet `7nRuVw3V…` | mainnet `4H3fP3ot…` |
  |---|---|---|
  | Mr. McRitchie, personal | `3Qj4v9qjhXgkru6zCRCErRVhy8Q6qU3NrNpvpXLTZboA` | `3Qj4v9qjhXgkru6zCRCErRVhy8Q6qU3NrNpvpXLTZboA` |
  | Mr. McRitchie, Phantom | `7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr` | `7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr` |
  | Mr. McRitchie, personal | — | `9gACbzsCLmkYF9Yx1EBGmwMvvyfuTquJ6qs8QsoQvHXf` |
  | the agent (`solana.turf.admin`) | `BLSBw8fXHzZc5pbaYCKMpMSsrtXBTbWXpUPVzMrXx9oo` | `BLSBw8fXHzZc5pbaYCKMpMSsrtXBTbWXpUPVzMrXx9oo` |
  | the app's HOT system key | `2eGs8G3w…` (`solana.turf.system.devnet`) | `7auwTLSv…` (`solana.turf.system`) |
  | Xan | `8K81w4e6…` — **still seated** | removed |

  - Threshold: **3** on both.
  - **Mason `CytJS23p…` was removed from BOTH clusters** — verified absent from each account's raw data. He should not be re-added; `F6f8h5yy…` was retired in the 2026-06-02 rotation and must never be placed on a multisig again.
  - ⚠ **Xan `8K81w4e6…` was removed from MAINNET ONLY. He is still a DEVNET member** (member slot 4, mask 7). "Removed from both" was written down on 2026-09-15 and is wrong; re-derive per cluster rather than repeating it.
  - **`scripts/squad-upgrade.js` cannot drive a MAINNET upgrade.** It signs as `ALEX_BOT_KEY` (`8K81…`) and cosigns with `MASON_KEY` (`CytJ…`), and neither is seated on mainnet. On devnet `8K81…` can still cast one of the three approvals, but `CytJ…` cannot, so the script cannot reach threshold unaided there either. `scripts/squad.json`'s `members` block still lists the old three and is provenance only.
  - ⚠ **THE HOT SYSTEM KEY HOLDS UPGRADE AUTHORITY, AND THAT CONTRADICTS THE STATED POLICY.** Both system keys are full `Initiate|Vote|Execute` Squads members. `7auwTLSv…` sits in Heroku config on a running `turf-monster-mainnet` web dyno and signs every entry and every payout, and it also votes on program upgrades. The policy written throughout these docs — that the hot key must never hold upgrade authority — is sound and is **not** what the chain implements. Closing the gap is a Squads config transaction, not a documentation edit; it needs its own task and Mr. McRitchie's signature.
  - Vault PDA (the program upgrade authority) is unchanged: mainnet `Bk9sS7ii…`, devnet `BW13kgfi…`.

  > **ON MAINNET THE AGENT ALREADY HOLDS TWO SEATS OF FIVE AGAINST A THRESHOLD
  > OF THREE, SO ONE FILING IS ALL IT WOULD TAKE.** It can read `BLSBw8…`
  > (`solana.turf.admin`) and — because that key is filed in the same
  > agent-readable `studio-agents` vault — the system key `7auwTL…`. Two of the
  > three approvals a Squads transaction needs. The other three members
  > (`3Qj4v9…`, `7ZDJ…`, `9gACbz…`) are Mr. McRitchie's own wallets, deliberately
  > filed in **no vault at all**. **Filing even ONE of them into agent-readable
  > storage hands the agent the threshold outright.** Not three filings — one.
  > If a ceremony needs his approvals, he gives them; the unblock is a
  > signature, never a filing.
  >
  > **On devnet that separation is already gone, by design.** The agent reaches
  > `BLSBw8…`, `8K81…` and `2eGs8G3w…` — three of five, the threshold — and can
  > upgrade unattended. That is appropriate for a test cluster and it is exactly
  > why a devnet rehearsal proves nothing about the mainnet ceremony.
  >
  > **TWO AUTHORITIES. THEY ARE STILL SEPARATE SYSTEMS, BUT ON MAINNET THEIR
  > MEMBERSHIP HAS CONVERGED — AND NOT BY DESIGN.** Re-measured at `finalized`
  > on 2026-09-15:
  >
  > | Wallet | Squads mainnet (program upgrade) | `VaultState.signers` target (the money) |
  > |---|---|---|
  > | system `7auwTL…` | ✅ **seated, mask 7** | slot 1 |
  > | admin `BLSBw8…` | ✅ | slot 2 |
  > | Alex Phantom `7ZDJ…` | ✅ | slot 3 |
  > | Alex two `3Qj4v9…` | ✅ | slot 4 |
  > | Alex three `9gACbz…` | ✅ | slot 5 |
  >
  > **Squads mainnet is FIVE at threshold 3 and is LIVE.** **`VaultState` is
  > FIVE and is the TARGET** — on-chain it is still the old 2-of-3 (`8K81…`,
  > `7ZDJ…`, `CytJ…`) on both clusters, measured the same day, until an
  > `update_signers` transaction runs. The two sets differ today in THRESHOLD
  > and in what they govern, not in membership.
  >
  > ⚠ **`solana.turf.system` WAS MEANT TO BE OFF SQUADS. IT IS NOT.** The
  > policy is right: it is the app's HOT operational key, it lives in Heroku
  > config on a running web server, it signs on every entry and every payout,
  > and that makes it the most exposed key in the system and the last one that
  > should hold program upgrade authority — which it has no job doing anyway,
  > since upgrading a program is a rare, deliberate, human act and never
  > something the server does unattended. The chain does not implement that
  > policy: `7auwTL…` is a full `Initiate|Vote|Execute` member of the mainnet
  > Squad, and `2eGs8G3w…` is the same on devnet. **Do not read this table as
  > the policy being satisfied.** Removing them is a Squads config transaction
  > with Mr. McRitchie's signature on it, and it needs its own task.
  >
  > The agent therefore holds **2 of 5 on mainnet Squads** (`BLSBw8…` plus the
  > agent-readable `7auwTL…`) against a threshold of 3 — one short, so a
  > mainnet upgrade still needs Mr. McRitchie. On devnet the agent reaches
  > **3 of 5** (`BLSBw8…`, `8K81…`, `2eGs8G3w…`) and can act alone. That
  > devnet-autonomous / mainnet-handoff split is the whole reason step 1 of the
  > ceremony reads differently per cluster; `docs/SOLANA.md` states it once and
  > everything else defers to it.
  >
  > **THE FIVE-MEMBER VAULT SET IS BLOCKED ON A PROGRAM UPGRADE, NOT ON A
  > CEREMONY.** The DEPLOYED v0.25.0 declares `update_signers(new_signers:
  > [Pubkey; 3])` against `signers: [Pubkey; 3]` — it can only ever write
  > THREE, and it replaces the whole set. `accepted` widens that to
  > `[Pubkey; MAX_SIGNERS]` alongside `signers_ext`. So the order is forced:
  >
  > 1. **Restore a working upgrade path.** `scripts/squad-upgrade.js` signs as
  >    `8K81…` and cosigns with `CytJ…`, both removed from Squads on
  >    2026-09-15, so it cannot drive an upgrade today. A current member has to
  >    sign — the agent holds `BLSBw8…` — and three of the five approve.
  > 2. **Deploy v0.26.** This is what puts `signers_ext` on-chain.
  > 3. **Re-pin `EXPECTED_IDL_HASH`** on `turf-monster-mainnet` from the BUILT
  >    IDL — the v0.26 change alters the IDL.
  > 4. **Only then `update_signers`** with the five-member set.
  >
  > Attempting step 4 first does not fail harmlessly: it spends a ceremony and
  > Mr. McRitchie's signatures on a transaction the live program cannot accept.
  >
  > **Never write "the multisig" unqualified.** Say *Squads* or *`VaultState`*
  > every time. The unqualified form is what produced the stale claims this
  > block replaces. `SOLANA_MULTISIG_SIGNERS` below models `VaultState`, not
  > Squads — so a Squads change is never a reason to edit it.
  >
  > **HOW MANY SLOTS `VaultState` HAS DEPENDS ON WHICH BUILD YOU MEAN.** The
  > DEPLOYED v0.25.0 declares `signers: [Pubkey; 3]`. turf-vault's `accepted`
  > APPENDS `signers_ext: [Pubkey; 2]` at offset 1443 and reads the set through
  > `all_signers()` — five slots, appended rather than widened so the upgrade
  > stays layout-compatible on a `zero_copy` singleton. "Three" and "five" are
  > each true of a different build; that gap is the design, not a discrepancy.
  > Check what the cluster runs before trusting any count.
- [ ] **1Password updated**: `agent.mason.solana.mainnet` (Mason mainnet keypair), `agent.managed_wallet.mainnet` (32-byte hex MANAGED_WALLET_ENCRYPTION_KEY for mainnet — generate fresh, do NOT reuse the devnet one). The Turf Solana keys are ALREADY filed and need no mainnet-suffixed twin — all three live in `studio-agents` with HYPHENATED labels (`wallet-address`, `private-key`), verified 2026-09-15: `solana.turf.admin` (`BLSBw8fX…`, the agent governance identity), `solana.turf.system` (`7auwTLSv…`, the server operational key for MAINNET) and `solana.turf.system.devnet` (`2eGs8G3w…`, the same for devnet/QA). Note `solana.turf.admin` is one of the agent's Squads seats. ⚠ **The system keys were meant to be excluded from Squads and are NOT** — `7auwTLSv…` is a full mask-7 member of the mainnet Squad and `2eGs8G3w…` of the devnet one, re-measured at `finalized` 2026-09-15. `solana.turf.system` also belongs to the `VaultState.signers` set (slot 1 of the five-member target). The rule a hot key that signs every entry and payout from a web dyno must not also hold program upgrade authority still stands as policy; closing the gap is a Squads config transaction, tracked separately.
- [ ] **Mainnet RPC URL** chosen (Helius / QuickNode / Triton — NOT public api.mainnet-beta.solana.com for production traffic).
- [ ] **Stripe live keys** ready: `STRIPE_SECRET_KEY` (sk_live_...), `STRIPE_WEBHOOK_SECRET` (whsec_... — created against the live mode endpoint).
- [ ] **Browse `/admin/transactions`** on devnet — confirm no PendingTransactions are stuck in :pending. They won't carry over but cleaner state is easier to debug.

---

## 1. Build the mainnet program binary

```bash
cd /Users/alex/projects/turf-vault
anchor build -- --features mainnet
shasum -a 256 target/deploy/turf_vault.so
```

- [ ] Build succeeds. Note the binary SHA — you'll compare after deploy.
- [ ] Confirm the IDL was emitted at `target/idl/turf_vault.json`.
- [ ] Sanity-check the constants compiled in:
  ```bash
  strings target/deploy/turf_vault.so | grep -c "EPjFW"  # must be > 0 (mainnet USDC)
  strings target/deploy/turf_vault.so | grep -c "Es9vM"  # must be > 0 (mainnet USDT)
  ```

---

## 2. Deploy the program to mainnet (via Squads)

The Squads V4 multisig becomes the upgrade authority from the very first deploy.

```bash
# Generate a fresh program keypair (DO NOT reuse devnet's Dx8u...)
solana-keygen new --no-bip39-passphrase -o target/deploy/turf_vault-mainnet-keypair.json
solana address -k target/deploy/turf_vault-mainnet-keypair.json
# → MAINNET_PROGRAM_ID (record this — needed for env vars)

# Update declare_id!() in lib.rs to MAINNET_PROGRAM_ID, then rebuild
# (alternative: use Anchor's --program-id flag if your toolchain supports it)

# Deploy with Squads vault as the upgrade authority from t=0
export ANCHOR_PROVIDER_URL=https://api.mainnet-beta.solana.com  # or your private RPC
solana program deploy target/deploy/turf_vault.so \
  --program-id target/deploy/turf_vault-mainnet-keypair.json \
  --upgrade-authority <SQUADS_VAULT_PDA> \
  --url $ANCHOR_PROVIDER_URL
```

- [ ] Deploy succeeds (~3-5 SOL spent from Xan mainnet wallet).
- [ ] `solana program show MAINNET_PROGRAM_ID --url mainnet-beta` shows the Squads vault PDA as upgrade authority.

> **After this initial deploy**, all future program upgrades require Squads approval via `turf-vault/scripts/squad-upgrade.js` — the live threshold and membership are stated once in `docs/SOLANA.md` and re-derived there, never restated here. `anchor deploy` will fail silently once the Squads vault is the authority. See `turf-vault/docs/CURRENT_DEPLOYMENT.md` for the current upgrade rule.

---

## 3. Initialize the vault (Alex's Phantom signs)

The v0.15.0 mainnet build's `INIT_AUTHORITY = 7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr` (Alex Phantom). The Rails server's Xan key WILL BE REJECTED.

**Quickest path** (if the Init UI from the prompt isn't built yet): use an `anchor` CLI command.

```bash
# From a machine with Alex's keypair available (NOT the Heroku server):
solana config set --keypair /path/to/alex_phantom.json --url $ANCHOR_PROVIDER_URL

# Confirm pubkey
solana address  # must equal 7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr

# Run initialize via a quick TS script (write a tiny one based on the
# existing tests/turf_vault.ts pattern — copy the initialize block at line 121)
ANCHOR_PROVIDER_URL=https://api.mainnet-beta.solana.com \
ANCHOR_WALLET=/path/to/alex_phantom.json \
yarn run ts-mocha -p ./tsconfig.json -t 1000000 scripts/init-mainnet.ts
```

- [ ] VaultState PDA exists at the canonical address: `solana account <VAULT_STATE_PDA> --url mainnet-beta`.
- [ ] Three signers + threshold=2 + paused=false visible on-chain.
- [ ] If the `Init UI` was built (M5 prompt's sibling): use `/admin/vault_init` instead.

---

## 4. Create the first Season

Same pattern as devnet — any 1-of-3 vault signer creates. Xan is fine.

```bash
# From a machine with Xan's mainnet key:
SOLANA_NETWORK=mainnet-beta \
SOLANA_RPC_URL=$ANCHOR_PROVIDER_URL \
SOLANA_PROGRAM_ID=<MAINNET_PROGRAM_ID> \
SOLANA_ADMIN_KEY=<xan_mainnet_base58> \
bin/rails runner '
  result = Solana::Vault.new.create_season(
    season_id: 1,
    name: "World Cup 2026 — Mainnet",
    schedule: [25, 19, 14, 10, 7],
    start_at: Time.parse("2026-06-01").to_i
  )
  puts result.inspect
'
```

- [ ] Season PDA visible on-chain. `season_id`, `seed_schedule` match input.

---

## 5. Re-pin the IDL hash

The freshly **built** IDL — NOT `anchor idl fetch` (Squad deploys don't update the on-chain IDL account; you'd get the stale one).

```bash
cp /Users/alex/projects/turf-vault/target/idl/turf_vault.json \
   /Users/alex/projects/turf-monster/config/turf_vault.idl.json

cd /Users/alex/projects/turf-monster
shasum -a 256 config/turf_vault.idl.json
# → EXPECTED_IDL_HASH_VALUE
```

- [ ] Record EXPECTED_IDL_HASH_VALUE for the env-var step below.

---

## 6. Set Heroku env vars (mainnet config)

**Critical**: set ALL of these BEFORE the first deploy (`bin/deploy turf-monster-mainnet`). The boot guards refuse to start without them: OPSEC-012 names each missing var during eager load, and OPSEC-014 refuses on the IDL pin. OPSEC-039, the genesis-hash alignment check, is the one guard that does NOT refuse on a bad `SOLANA_RPC_URL` — it fails closed only on a genesis hash that came back and DISAGREED. An endpoint it cannot reach or authenticate against is logged and boot continues, on purpose (see `config/initializers/solana_network_alignment.rb`).

```bash
heroku config:set --app turf-monster-mainnet \
  SOLANA_NETWORK=mainnet-beta \
  SOLANA_RPC_URL=<your-private-mainnet-rpc> \
  SOLANA_PROGRAM_ID=<MAINNET_PROGRAM_ID> \
  SOLANA_USDC_MINT=EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v \
  SOLANA_USDT_MINT=Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB \
  SOLANA_ADMIN_KEY=<xan_mainnet_base58> \
  SOLANA_MULTISIG_SIGNERS=8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd,7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr,CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR \
  SOLANA_MULTISIG_THRESHOLD=2 \
  SOLANA_MULTISIG_COSIGNER=7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr \
  EXPECTED_IDL_HASH=<from step 5> \
  MANAGED_WALLET_ENCRYPTION_KEY=<freshly-generated 64 hex chars> \
  STRIPE_SECRET_KEY=sk_live_... \
  STRIPE_WEBHOOK_SECRET=whsec_... \
  SENTRY_DSN=https://<key>@<org>.ingest.us.sentry.io/<project>  # prelaunch audit H3

# Sanity: SKIP_IDL_VERIFICATION MUST be unset (the v0.15.0 boot guard refuses
# to start production if this is set — see audit H4).
heroku config:unset SKIP_IDL_VERIFICATION --app turf-monster-mainnet 2>/dev/null
heroku config:unset SOLANA_SKIP_NETWORK_CHECK --app turf-monster-mainnet 2>/dev/null
heroku config:unset ENABLE_TEST_SCAFFOLDING --app turf-monster-mainnet 2>/dev/null  # disable $1 micro contests + the $5/3-token pack
```

- [ ] All vars set. `heroku config --app turf-monster-mainnet | grep SOLANA` matches the table above.
- [ ] `STRIPE_SECRET_KEY` starts with `sk_live_` (not `sk_test_`). The webhook rejects livemode mismatch (OPSEC-033).

---

## 7. Update Stripe webhook endpoint to live mode

In the Stripe dashboard, create a NEW webhook endpoint pointing to your prod URL:

- URL: `https://app.turfmonster.media/webhooks/stripe`
- Events: `checkout.session.completed`, `charge.dispute.created`, `charge.dispute.funds_withdrawn`, `charge.refunded`
- Mode: **Live** (not Test)

Copy the resulting `whsec_...` into Heroku as `STRIPE_WEBHOOK_SECRET` (already done in step 6 if you had it ready).

- [ ] Endpoint shows green in Stripe dashboard.
- [ ] Test event delivered + 200 OK.

---

## 8. Commit the IDL + push Rails

```bash
cd /Users/alex/projects/turf-monster
git add config/turf_vault.idl.json
git commit -m "Mainnet IDL pin (program <MAINNET_PROGRAM_ID>)"
bin/deploy turf-monster-mainnet  # → heroku-mainnet remote; runs the IDL allow-list re-pin + migrations
```

- [ ] Heroku build succeeds (no IDL hash mismatch, no env-var failures).
- [ ] First request to `https://app.turfmonster.media` returns 200.

---

## 9. Verify migrations ran

`bin/deploy` (step 8) runs migrations in Heroku's **release phase** — atomically
with promotion, so a failed migration blocks the release. No manual step needed;
just confirm the release-phase output was clean:

```bash
heroku releases:output --app turf-monster-mainnet
```

- [ ] Migration output clean (ran during the release phase).

---

## 10. Post-deploy smoke test (15 min, with a real $5)

Do this with a real Phantom wallet on mainnet. Plan to spend ~$5.

- [ ] **Sign up** with Phantom — UserAccount PDA visible on-chain (`solana account <USER_PDA> --url mainnet-beta`).
- [ ] **Deposit $5 USDC** — vault USDC PDA balance increases by 5, UserAccount.balance shows 5.
- [ ] **Enter a $1 micro contest** (if you didn't disable `ENABLE_TEST_SCAFFOLDING`) or a real $19 contest.
      The `micro` tier is $1.00 entry / 9 entries / $5-$2-$2 payouts. Since 2026-08-27 production BOOTS
      with the flag on (it logs at ERROR + Sentry rather than crashing), so this rehearsal is reachable
      on mainnet — but the same flag also sells 3 entry tokens for $5, so unset it when you finish.
- [ ] **Withdraw $5** — succeeds (under $100 cap). `daily_withdrawn` on-chain = 5_000_000.
- [ ] **Attempt to withdraw $96 more** — succeeds (cumulative $101 would fail, but $96 makes $101 wait — actually $5 + $96 = $101 so this should FAIL with WithdrawDailyCapExceeded). Confirm the cap fires.
- [ ] **Pause vault** via the (yet-to-be-built) /admin/vault_state UI or via a one-shot script. Confirm deposit + withdraw return VaultPaused.
- [ ] **Unpause**. Confirm operations resume.

---

## 11. Update internal docs

- [ ] `turf-monster/docs/SOLANA.md`: update the Deployment section with the mainnet program ID + URL.
- [ ] `turf-vault/docs/CURRENT_DEPLOYMENT.md`: update the current deployment section to point to mainnet.
- [ ] Save a memory record (`project_turf_mainnet_launch_2026_MM_DD.md`) noting the new program ID, vault PDA, season PDA, IDL hash, and any deviations from this runbook.

---

## 12. Day-1 monitoring

- [ ] Heroku logs streaming: `heroku logs --tail --app turf-monster-mainnet`. Watch for `VaultPaused`, `WithdrawDailyCapExceeded`, any 500s.
- [ ] Stripe dashboard: monitor for disputes / unusual chargeback patterns.
- [ ] On-chain: watch `vault_usdc` PDA balance — should grow with deposits, shrink with payouts/withdrawals. Spikes warrant a pause.
- [ ] Set yourself a calendar reminder to verify the Squads cosign flow works end-to-end against mainnet within the first week (grade + cosign + settle on a small contest).

---

## Rollback plan

If something goes wrong post-launch:

1. **Suspected exploit**: pause the vault immediately via a **`VaultState` 2-of-3 cosign** — `pause` is a turf-vault instruction gated by `vault_state.validate_multisig`, NOT a Squads transaction; Squads governs program upgrades only (use the M5 UI once built, or a one-shot script). Pause is one TX away and stops all user-facing funds movement.
2. **Bad Rails deploy**: `heroku rollback --app turf-monster-mainnet` — instant revert.
3. **Bad program deploy**: roll forward, not back. Build a fix + new buffer + `node scripts/squad-upgrade.js`. There's no "downgrade" path on Solana — but the program data is forward-compatible if you preserve the layout.

The vault paused state DOES persist across program upgrades (it's in VaultState, not program code) so pausing → fixing → upgrading → unpausing is the standard recovery dance.

---

## Open follow-ups (recommend before mainnet, OK to defer to week 2)

- C3 — Mason's mainnet key to genuinely separate custody (not in Alex's 1Password)
- C1 / C2 — KMS-managed `MANAGED_WALLET_ENCRYPTION_KEY` (AWS KMS or HashiCorp Vault)
- H3 — `wallet: Signer` on create_user_account (username squatting)
- H5 — per-day cap on mint_entry_token
- H6 — time-based on-chain contest lock
- M5 UI — vault pause/unpause admin page (prompt provided)
- H1 UI — first-deploy initialize page (prompt provided)
