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
  - [ ] Alex Bot mainnet wallet: ≥ 5 SOL (program deploy + initial Season + sundry)
  - [ ] Alex Phantom mainnet wallet: ≥ 0.05 SOL (will sign initialize once)
  - [ ] Mason mainnet wallet: ≥ 0.05 SOL (will Squads-cosign deploys + treasury ops)
- [ ] **Squads V4 vault created on mainnet** with the same 3 signers as devnet:
  - Alex Bot: `F6f8h5yynbnkgWvU5abQx3RJxJpe8EoQmeFBuNKdKzhZ`
  - Alex: `7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr`
  - Mason: `CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR`
  - Threshold: 2
  - Record the new vault PDA → it becomes the program upgrade authority.
- [ ] **1Password updated**: `agent.alex.solana.mainnet` (Alex Bot mainnet keypair), `agent.mason.solana.mainnet` (Mason mainnet keypair), `agent.managed_wallet.mainnet` (32-byte hex MANAGED_WALLET_ENCRYPTION_KEY for mainnet — generate fresh, do NOT reuse the devnet one).
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

- [ ] Deploy succeeds (~3-5 SOL spent from Alex Bot mainnet wallet).
- [ ] `solana program show MAINNET_PROGRAM_ID --url mainnet-beta` shows the Squads vault PDA as upgrade authority.

> **After this initial deploy**, all future program upgrades require 2-of-3 cosign via `turf-vault/scripts/squad-upgrade.js`. `anchor deploy` will fail silently once the Squads vault is the authority. See `turf-vault/docs/CURRENT_DEPLOYMENT.md` for the current upgrade rule.

---

## 3. Initialize the vault (Alex's Phantom signs)

The v0.15.0 mainnet build's `INIT_AUTHORITY = 7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr` (Alex Phantom). The Rails server's Alex Bot key WILL BE REJECTED.

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

Same pattern as devnet — any 1-of-3 vault signer creates. Alex Bot is fine.

```bash
# From a machine with Alex Bot's mainnet key:
SOLANA_NETWORK=mainnet-beta \
SOLANA_RPC_URL=$ANCHOR_PROVIDER_URL \
SOLANA_PROGRAM_ID=<MAINNET_PROGRAM_ID> \
SOLANA_ADMIN_KEY=<alex_bot_mainnet_base58> \
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
  SOLANA_ADMIN_KEY=<alex_bot_mainnet_base58> \
  SOLANA_MULTISIG_SIGNERS=F6f8h5yynbnkgWvU5abQx3RJxJpe8EoQmeFBuNKdKzhZ,7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr,CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR \
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

1. **Suspected exploit**: pause the vault immediately via 2-of-3 Squads cosign (use the M5 UI once built, or a one-shot script). Pause is one TX away and stops all user-facing funds movement.
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
