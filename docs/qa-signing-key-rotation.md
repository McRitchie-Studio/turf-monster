# Giving turf-monster-qa its own signing key

**Status: NOT RUN.** This is the ceremony runbook. The tooling it uses (the
isolation guard in warn mode and the `bin/qa-signer-rotation` dry run) is built.
The ceremony itself is Mr. McRitchie's to run: it needs a new private key and a
devnet transaction signed by current vault signers. No agent signs, sends,
stores, or reads a key in any step below.

**Mainnet is untouched.** QA runs devnet, and each cluster's `VaultState` is its
own account. Nothing here changes mainnet's signer set, mainnet's config, or
`turf-monster-mainnet`.

## Why

`turf-monster-qa` and `turf-monster-mainnet` carry the same `SOLANA_ADMIN_KEY`
(compared by hash on 2026-09-25). That key is Xan,
`8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd`: a signer in the MAINNET
`VaultState` and the fee payer on production's server transactions. Anything
that runs on the QA dyno can therefore sign as production on mainnet, and
`create_contest`, `mint_entry_token` and `grant_seeds` need only one signature.

A new key alone does not fix this. Every admin instruction checks that its
signer is in `VaultState`'s signer set, so a key the devnet vault does not know
fails `Unauthorized` on every call. QA would be isolated and dead. So the new key
has to be seated on the devnet vault first, and only then handed to QA.

## What is on chain (read 2026-09-27)

| Fact | Value | How to re-read |
|---|---|---|
| Devnet program | `EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ`, v0.25.0 (executable SHA-256 `a0611d29…`, slot 468716417) | turf-vault `docs/CURRENT_DEPLOYMENT.md`, "Reading the Version row off the chain" |
| Devnet `VaultState` | `J7b5g9uS5M2Nog1Ly1UATXTDMtXdpXK3JffRAHXGHkK2`: `8K81…` (Xan), `7ZDJ…` (Alex), `CytJ…` (Mason); slots 4 and 5 empty | `bin/qa-signer-rotation --show` |
| `GovernanceConfig` | absent, so the v0.25 rules apply | `bin/qa-signer-rotation --show` |

The v0.25 program has three fixed slots and takes exactly two signatures, and
**both signers must stay in the new set** (`SignerContinuityRequired`, 6017). So
today the QA key cannot be ADDED; it takes one current signer's slot. The two
empty slots belong to v0.26, which devnet does not run yet.

## Step 1 — Choose the rotation (a decision, not a command)

| Option | New devnet set | Signed by | What it costs |
|---|---|---|---|
| **A. QA takes Mason's slot** (recommended on v0.25) | `8K81…`, `7ZDJ…`, QA | Xan + Alex. On `/admin/authorities` the QA server leads with its current key; you sign in Phantom | `bin/qa-contest-rehearsal` cosigns settlement as Mason, so its settle step stops working on devnet until its cosigner moves (a small follow-up). Mason's slot was already slated for retirement (turf-vault `docs/SIGNER_ROTATION.md`). QA never loses authority at any moment |
| B. QA takes Xan's slot | QA, `7ZDJ…`, `CytJ…` | Alex + Mason, both as wallet signatures | QA can do nothing between the chain change and its config flip, because its current key has just been evicted. Local development also loses devnet vault authority: the primary checkout's `.env` derives `8K81…` (measured 2026-09-27, public key only) |
| C. Wait for v0.26 on devnet, then append | `8K81…`, `7ZDJ…`, `CytJ…`, QA | all three current signers (`update_signers` needs 3 on v0.26) | Nothing breaks, but it waits on the devnet v0.26 upgrade, `init_governance`, and `SOLANA_VAULT_GOVERNANCE` on QA. That is a separate ceremony |

Agent reach does not get worse under any option: today an agent holds Xan and
Mason, two of three. Under A it holds Xan and the QA key, still two of three, on
devnet only. The five-signer redesign is what removes that, not this ceremony.

## Step 2 — Generate the QA keypair (Mr. McRitchie, offline)

Use your own terminal. Print and paste the public key only.

```bash
f="$(mktemp -t qa-signer)"                                   # never `cat` this file
solana-keygen new --no-bip39-passphrase --silent --outfile "$f"
solana-keygen pubkey "$f"                                    # the QA PUBLIC key
```

`--silent` suppresses the seed phrase. Never use `-o -`: it prints the secret.

## Step 3 — File it in 1Password

This follows the credential-filing SOP (`mcritchie-studio`,
`docs/agents/agents/steffon/sops/credential-filing.md`). `.env.example` already
reserves the title **`solana.turf.system.devnet`** for QA's system wallet. If that
item already exists, use its key instead of the one from step 2, and do not file
a duplicate. Vault: **`studio-applications`**, because the consumer is a Heroku
config var. Labels are hyphenated, to match the other Solana items.

`SOLANA_ADMIN_KEY` wants the **base58** 64-byte secret, not the JSON array that
`solana-keygen` writes. Convert it straight into a variable, never onto the
screen:

```bash
# Admin lane first (the SOP, section 4), then:
QA_PUBKEY="$(solana-keygen pubkey "$f")"
VALUE="$(ruby -rjson -e 'a="123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"; b=JSON.parse(File.read(ARGV[0])).pack("C*"); n=b.unpack1("H*").to_i(16); s=+""; while n>0; n,r=n.divmod(58); s.prepend(a[r]); end; print "1"*b.bytes.take_while(&:zero?).size + s' "$f")"
[ -n "$VALUE" ] || { echo "VALUE is empty — refusing to file"; exit 1; }

op item create --category "API Credential" --vault studio-applications \
  --title "solana.turf.system.devnet" \
  --url "https://explorer.solana.com/address/$QA_PUBKEY?cluster=devnet" \
  "private-key[concealed]=$VALUE" \
  "wallet-address[text]=$QA_PUBKEY" \
  "used-by[text]=turf-monster-qa SOLANA_ADMIN_KEY (devnet system wallet)" \
  "notesPlain=scope: devnet VaultState signer (turf-vault EQGF…bpMJ) and QA fee payer
CAN: sign devnet vault instructions as one signer; pay devnet fees
CANNOT: sign anything on mainnet; it is in no mainnet signer set
Never copy this value to another app or to a local .env."
unset VALUE
rm -P "$f"
```

Read back the public field only: `op item get solana.turf.system.devnet --vault
studio-applications --fields wallet-address`.

## Step 4 — Fund it with devnet SOL

The QA key becomes QA's fee payer, and an unfunded fee payer fails every
transaction. Airdrops take a public key:

```bash
solana airdrop 2 "$QA_PUBKEY" --url devnet
solana balance "$QA_PUBKEY" --url devnet
```

## Step 5 — Dry run

From a turf-monster checkout. It reads devnet, holds no key, and cannot send.

```bash
bin/qa-signer-rotation --show
# Option A:
bin/qa-signer-rotation --qa-pubkey "$QA_PUBKEY" \
  --replace CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR \
  --cosigners 8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd,7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr
```

It checks the plan against the rules of the program devnet actually runs:
authorizers in the set, no duplicates, the signature count, continuity, the slot
count, and whether `--append` has a slot to use. It also refuses a QA key that is
already a signer or is another environment's system wallet. It exits non-zero
and names the rule when a plan fails, and prints the exact values to sign when it
passes. The chain is still the real gate.

## Step 6 — Sign the devnet signer change (Mr. McRitchie)

For option A or B, on the v0.25 program: sign in to **turf-monster-qa** as an
admin, open `/admin/authorities`, and enter the slots and authorizers exactly as
the dry run printed them. Arm, collect the signatures, broadcast, and the page
reads the set back. For option C, on v0.26, use turf-vault's
`scripts/rotate-devnet-signers.js`, which is a dry run until `--send`.

## Step 7 — Confirm the chain accepted it

```bash
bin/qa-signer-rotation --show      # the QA public key must appear in the set
```

Do not go on until it does.

## Step 8 — Point turf-monster-qa at the new key (QA ONLY, never mainnet)

```bash
heroku config:set SOLANA_ADMIN_KEY="$(op read 'op://studio-applications/solana.turf.system.devnet/private-key')" \
  --app turf-monster-qa
```

Check whether QA overrides the signer list, and if it does, set it to the new
set. This prints true or false, not values:

```bash
heroku config --json --app turf-monster-qa | jq 'has("SOLANA_MULTISIG_SIGNERS")'
```

**Why the chain goes first.** QA's server signs every admin instruction with
`SOLANA_ADMIN_KEY`, and the program accepts only keys in the signer set. If the
config flips first, QA signs with a key the vault has never heard of, and every
contest creation, mint and grant fails `Unauthorized` until the chain catches
up. And if the chain change then fails, QA stays dead. With the chain first, QA
keeps working on its old key (options A and C) until the flip, and afterward it
works on the new one.

**Rollback.** `heroku rollback <previous release> --app turf-monster-qa` restores
the previous config vars. Under options A and C the old key is still a devnet
signer, so QA works again at once. It also means QA shares production's key
again, so treat rollback as a pause, not a resting state.

## Step 9 — Verify QA

- The boot log carries one `[signer-isolation]` line. It still warns "unfiled"
  until step 10, but it must no longer say "holds production's system wallet".
- `/admin/authorities` on QA names the new key as the server's signing identity.
- One routine devnet action succeeds, such as creating a test contest.

## Step 10 — File QA's public key

In a turf-monster PR, set `qa.system_wallet` in `config/solana_signers.yml` to
the QA public key. After QA deploys it, the boot line reads OK, and the next
`bin/deploy` pre-flight prints an OK line for both apps.

## Step 11 — Turn the guard to enforce

Only after one `bin/deploy` pre-flight shows both apps OK: set `mode: enforce` in
`config/solana_signers.yml` in a PR. From then on a production deploy refuses
whenever either app's key is not its own environment's system wallet.
`SIGNER_ISOLATION=enforce`, in the deploying shell or on an app, escalates in the
meantime. Nothing can relax a committed `enforce`.

## The guard, briefly

| Where | Mode | On a finding |
|---|---|---|
| `bin/deploy` pre-flight, for every app in `config/solana_signers.yml` | warn (default) | prints the finding, and the deploy continues |
| `bin/deploy` pre-flight | enforce | refuses the deploy before anything is pushed |
| Boot, on deployed apps (`config/initializers/solana_signer_isolation.rb`) | either | logs an ERROR line and records one ErrorLog from `web.1`. It never refuses |

It compares the public key that `SOLANA_ADMIN_KEY` derives, never the string,
and prints public keys only. A key that is absent, empty, or not derivable, and a
config that cannot be read, are all findings, because absence is not isolation.
Rule: `lib/solana/signer_isolation.rb`. Tests:
`test/lib/signer_isolation_test.rb`, `test/lib/deploy_signer_isolation_test.rb`,
`test/services/solana/signer_isolation_boot_test.rb`,
`test/services/solana/qa_signer_rotation_test.rb`.

## What this ceremony does not fix

- **Development.** The primary checkout's `.env` derives production's key,
  `8K81…` (measured 2026-09-27, public key only). A development identity needs a
  vault slot of its own, and `development.system_wallet` stays null until one
  exists. The boot guard does not run in development.
- **Mainnet governance.** Production keeps `8K81…`, which an agent can reach.
  The five-signer redesign (turf-vault `docs/SIGNER_ROTATION.md`) is what takes
  governance out of agent reach.
- **The rehearsal cosigner** under option A, as noted in step 1.
