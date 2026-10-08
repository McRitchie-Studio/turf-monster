# Giving turf-monster-qa its own signing key

**Status: PARTLY RUN. The devnet signer change (step 6) has NOT run, and QA
still holds production's key.** Where each step stands, as of 2026-10-08:

| Step | State |
|---|---|
| 1. Choose the rotation | **Open: Mr. McRitchie's decision.** Option A's dry run passes with the key below |
| 2–3. The QA key, filed in 1Password | Done before this runbook was written: `solana.turf.system.devnet`, `2eGs8G3wzhEeNQQU2Q86BmmA2xTpDbMMae3Y1bvpZfx9`. No new key is generated |
| 4. Fund it | SOL done: 995,118,360 lamports on devnet at `finalized`, 2026-10-08. Re-read before the flip. **USDC mint authority: open (step 4)** |
| 5. Dry run | Option A passes (2026-10-08). Re-run it on the day |
| 6–7. Sign and confirm the devnet signer change | **NOT RUN. Mr. McRitchie signs** |
| 8–9. Point turf-monster-qa at the key, verify | **NOT RUN.** Only after step 7 |
| 10. File QA's public key | Done ahead of the flip (task `turf-qa-gets-own-signer`) |
| 11. Turn the guard to enforce | **NOT RUN.** A separate decision |

The tooling (the isolation guard in warn mode and the `bin/qa-signer-rotation`
dry run) is built. The signer change is Mr. McRitchie's to sign: it is a devnet
transaction that current vault signers authorize. No agent signs or sends a
transaction in any step below. An agent reads the QA key only through a pipe
that prints its public half (step 3's proof, run 2026-10-08).

**Do not start step 6 in the hours before a QA release that must settle a
contest.** Option A evicts Mason, whose key `bin/qa-contest-rehearsal` uses to
cosign settlement (step 1). Move that cosigner first, or settle by link.

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

The v0.25 program has three fixed slots, and its `update_signers` has exactly
two signer accounts, `admin` and `cosigner`: name **exactly two cosigners**, never
three. **Both must stay in the new set** (`SignerContinuityRequired`, 6017). A
third named cosigner is not a spare: the chain judges only the first two, so a
plan that evicts either of them fails on chain however many others stay. So
today the QA key cannot be ADDED; it takes the slot of the one current signer who
does not sign. The two empty slots belong to v0.26, which devnet does not run yet.
Read at turf-vault tag `v0.25.0`, `instructions/update_signers.rs`.

## Step 1 — Choose the rotation (a decision, not a command)

| Option | New devnet set | Signed by | What it costs |
|---|---|---|---|
| **A. QA takes Mason's slot** (recommended on v0.25) | `8K81…`, `7ZDJ…`, QA | Xan + Alex. On `/admin/authorities` the QA server leads with its current key; you sign in Phantom | `bin/qa-contest-rehearsal` cosigns settlement as Mason, so its settle step stops working on devnet until its cosigner moves (a small follow-up). Mason's slot was already slated for retirement (turf-vault `docs/SIGNER_ROTATION.md`). QA never loses authority at any moment |
| B. QA takes Xan's slot | QA, `7ZDJ…`, `CytJ…` | Alex + Mason, both as wallet signatures | QA can do nothing between the chain change and its config flip, because its current key has just been evicted. Local development also loses devnet vault authority: the primary checkout's `.env` derives `8K81…` (measured 2026-09-27, public key only) |
| C. Wait for v0.26 on devnet, then append | `8K81…`, `7ZDJ…`, `CytJ…`, QA | all three current signers (`update_signers` needs 3 on v0.26) | Nothing breaks, but it waits on the devnet v0.26 upgrade, `init_governance`, and `SOLANA_VAULT_GOVERNANCE` on QA. That is a separate ceremony |

Agent reach does not get worse under any option: today an agent holds Xan and
Mason, two of three. Under A it holds Xan and the QA key, still two of three, on
devnet only. The five-signer redesign is what removes that, not this ceremony.

## Step 2 — Generate the QA keypair (SKIP: the key exists)

**Skip steps 2 and 3's filing.** QA's key was filed on 2026-09-15 as
`solana.turf.system.devnet`, in vault **`studio-agents`** (item id
`luzehmyewswpnbgytyawc25sdy`, labels `wallet-address` and `private-key`), and
its public key is `2eGs8G3wzhEeNQQU2Q86BmmA2xTpDbMMae3Y1bvpZfx9`. Run step 3's
proof and go to step 4 with:

```bash
QA_PUBKEY=2eGs8G3wzhEeNQQU2Q86BmmA2xTpDbMMae3Y1bvpZfx9
```

What follows in this step and the next is the recipe for a key that does not
exist yet. It applies again only if that item is ever lost or retired. Use your
own terminal, and print and paste the public key only.

```bash
f="$(mktemp -t qa-signer)"                                   # never `cat` this file
solana-keygen new --no-bip39-passphrase --silent --outfile "$f"
solana-keygen pubkey "$f"                                    # the QA PUBLIC key
```

`--silent` suppresses the seed phrase. Never use `-o -`: it prints the secret.

## Step 3 — File it in 1Password

This follows the credential-filing SOP (`mcritchie-studio`,
`docs/agents/agents/steffon/sops/credential-filing.md`). `.env.example` already
reserves the title **`solana.turf.system.devnet`** for QA's system wallet. **That
item exists** (step 2), so use its key and do not file a duplicate. It lives in
**`studio-agents`**, not in `studio-applications`, where the filing SOP would
put a key whose consumer is a Heroku config var. That is drift, recorded here
and not fixed: moving it is a filing act of its own, and every path below names
the vault the item is really in. A fresh filing, should one ever be needed,
goes to `studio-applications` as the recipe below says; then change the two
`op read` paths in this runbook to match. Labels are hyphenated, to match the
other Solana items.

`SOLANA_ADMIN_KEY` wants the **base58** 64-byte secret, not the JSON array that
`solana-keygen` writes. The secret never touches a shell variable or a command
line: Ruby reads the keypair file, converts it, and writes a JSON item template
to a pipe, and `op item create -` reads the concealed field from that pipe. The
`op` CLI's own help warns that assignment statements (`field[concealed]=…`) are
visible to other processes and land in shell history; the template on stdin is
its documented alternative. Only public values ride on the command line.

```bash
# Admin lane first (the SOP, section 4), then:
QA_PUBKEY="$(solana-keygen pubkey "$f")"
ruby -rjson -e '
  a = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  b = JSON.parse(File.read(ARGV[0])).pack("C*")
  abort "refusing: the keypair file is not 64 bytes" unless b.bytesize == 64
  n = b.unpack1("H*").to_i(16); s = +""
  while n > 0; n, r = n.divmod(58); s.prepend(a[r]); end
  s = "1" * b.bytes.take_while(&:zero?).size + s
  print JSON.generate("fields" => [{ "id" => "private-key", "label" => "private-key",
                                     "type" => "CONCEALED", "value" => s }])
' "$f" | op item create --category "API Credential" --vault studio-applications \
  --title "solana.turf.system.devnet" \
  --url "https://explorer.solana.com/address/$QA_PUBKEY?cluster=devnet" \
  - \
  "wallet-address[text]=$QA_PUBKEY" \
  "used-by[text]=turf-monster-qa SOLANA_ADMIN_KEY (devnet system wallet)" \
  "notesPlain=scope: devnet VaultState signer (turf-vault EQGF…bpMJ) and QA fee payer
CAN: sign devnet vault instructions as one signer; pay devnet fees
CANNOT: sign anything on mainnet; it is in no mainnet signer set
Never copy this value to another app or to a local .env." > /dev/null
```

`> /dev/null` because `op item create` prints the item it made. If `op` rejects
the one-field template, start from `op item template get "API Credential"` (it
holds no secret), add the `private-key` field to it the same way, and pipe that.
Never fall back to an assignment statement for the key.

Prove the filed secret signs as the QA key. This prints a public key and nothing
else; run it from a turf-monster checkout. It printed `2eGs8G3w…pZfx9` on
2026-10-08:

```bash
op read "op://studio-agents/solana.turf.system.devnet/private-key" \
  | ruby -r ./lib/solana/signer_isolation -e 'puts Solana::SignerIsolation.derive_pubkey($stdin.read)'
echo "$QA_PUBKEY"                                            # the two must match
[ -z "${f:-}" ] || rm -P "$f"                                # only when step 2 made a file
```

Read back the public field too: `op item get solana.turf.system.devnet --vault
studio-agents --fields label=wallet-address`.

## Step 4 — Fund it with devnet SOL

The QA key becomes QA's fee payer, and an unfunded fee payer fails every
transaction. Read the balance first. It held 0.995 SOL on 2026-10-08, which
needs no airdrop; ask the faucet once, and only if the read is low:

```bash
solana balance "$QA_PUBKEY" --url devnet
solana airdrop 2 "$QA_PUBKEY" --url devnet                   # only if the balance is low
```

**SOL is not all the server key needs on devnet.** The devnet USDC test mint,
`222Dcu2RgAXE3T8A4mGSG3kQyXaNjqePx7vva1RdWBN9`, names `8K81…` as its mint
authority (read at `finalized`, 2026-10-08), and the QA key owns no token
account. After step 8 QA's server signs `mint_spl` as the QA key, so the
faucet, the devnet deposit credit, `bin/qa-contest-rehearsal create` and an
operator-funded test contest all fail. **Open: Mr. McRitchie's decision,
before step 8.** Either move the mint authority to the QA key (one devnet
signature by `8K81…`; local development, which derives `8K81…`, then loses
devnet minting), or leave it and accept that QA cannot mint. Re-read it with
`spl-token display 222Dcu2RgAXE3T8A4mGSG3kQyXaNjqePx7vva1RdWBN9 --url devnet`.

## Step 5 — Dry run

From a turf-monster checkout. It reads devnet, holds no key, and cannot send.

```bash
bin/qa-signer-rotation --show
# Option A (the QA key takes Mason's slot; Xan and Alex sign and both stay):
bin/qa-signer-rotation --qa-pubkey "$QA_PUBKEY" \
  --replace CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR \
  --cosigners 8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd,7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr
# Option B (the QA key takes Xan's slot; Alex and Mason sign and both stay):
bin/qa-signer-rotation --qa-pubkey "$QA_PUBKEY" \
  --replace 8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd \
  --cosigners 7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr,CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR
```

Its first line names the rules it applied (`rules applied: turf-vault v0.25
update_signers` today). On v0.25 it refuses anything but exactly two cosigners,
and refuses a plan that evicts either of them: `--replace 8K81… --cosigners
8K81…,7ZDJ…,CytJ…` is refused here, because on chain it would fail 6017. It also
checks that the cosigners are current signers and distinct, the slot count, and
whether `--append` has a slot to use, and it refuses a QA key that is already a
signer or is another environment's system wallet. It exits non-zero and names
the rule when a plan fails. When a plan passes, it prints the exact values to
sign and the exact signer list for step 8, as one line:
`SOLANA_MULTISIG_SIGNERS=<slot 1>,<slot 2>,<slot 3>`. Keep that line. The chain is
still the real gate.

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

Only after step 7's `bin/qa-signer-rotation --show` lists the QA key. For
**every option** this step sets two config vars on `turf-monster-qa`, together,
in one release:

- `SOLANA_ADMIN_KEY`, the QA secret.
- `SOLANA_MULTISIG_SIGNERS`, QA's model of the devnet signer set, set to the
  value step 5 printed (public keys, in slot order). Left alone, QA keeps its
  old list and goes on offering an evicted key (Mason under A, Xan under B) as a
  cosigner. Under C it would omit the QA key.

First note the current release. It is what a rollback returns to:

```bash
heroku releases -n 1 --app turf-monster-qa
```

`heroku config:set` takes its values on the command line only, so it cannot
carry the secret. This uses the Platform API instead, which is the same call the
CLI makes, and it creates a release just as `config:set` does. The secret goes
from `op` into the request body over a pipe, and your Heroku token goes into a
header file readable only by you, so neither is ever an argument. The API answers
with every config var on the app, secrets included, so the body is discarded and
only the HTTP status is printed; `200` is success.

```bash
SIGNERS="<the value after SOLANA_MULTISIG_SIGNERS= from step 5>"   # public keys only
umask 077; h="$(mktemp)"
heroku auth:token | sed 's/^/Authorization: Bearer /' > "$h"
op read "op://studio-agents/solana.turf.system.devnet/private-key" \
  | SIGNERS="$SIGNERS" ruby -rjson -e 'print JSON.generate(
      "SOLANA_ADMIN_KEY" => $stdin.read.strip,
      "SOLANA_MULTISIG_SIGNERS" => ENV.fetch("SIGNERS"))' \
  | curl -sS -o /dev/null -w '%{http_code}\n' -X PATCH \
      https://api.heroku.com/apps/turf-monster-qa/config-vars \
      -H "Accept: application/vnd.heroku+json; version=3" \
      -H "Content-Type: application/json" \
      -H @"$h" --data-binary @-
rm -P "$h"
```

The trade-off, stated plainly: for the seconds this runs, the Heroku token sits
in a `0600` temp file, which `rm -P` then removes. That is the one argv-free
route to Heroku config; there is no stdin form of `heroku config:set`.

Read it back. Both lines print public keys only:

```bash
heroku config:get SOLANA_MULTISIG_SIGNERS --app turf-monster-qa        # must equal $SIGNERS
heroku config:get SOLANA_ADMIN_KEY --app turf-monster-qa \
  | ruby -r ./lib/solana/signer_isolation -e 'puts Solana::SignerIsolation.derive_pubkey($stdin.read)'
                                                                        # must equal $QA_PUBKEY
```

**Why the chain goes first.** QA's server signs every admin instruction with
`SOLANA_ADMIN_KEY`, and the program accepts only keys in the signer set. If the
config flips first, QA signs with a key the vault has never heard of, and every
contest creation, mint and grant fails `Unauthorized` until the chain catches
up. And if the chain change then fails, QA stays dead. With the chain first, QA
keeps working on its old key (options A and C) until the flip, and afterward it
works on the new one.

### Rollback

`heroku rollback <the release you noted> --app turf-monster-qa` restores both
config vars as they were: the old key, `8K81…`, and the old signer list (on
2026-10-08 QA set no `SOLANA_MULTISIG_SIGNERS` at all, so "the old list" is the
code default, `8K81…,7ZDJ…,CytJ…`). The old key's 1Password home is
`agent.xan.solana`, vault `studio-agents-admin`, field `private key`; a
rollback never needs to read it, because Heroku keeps the value in the release
it returns to. It
reverts **config only; it never touches the chain**, so whether QA works
afterwards depends on whether the chain still seats `8K81…`. Any rollback also
puts QA back on production's key, so treat it as a pause, not a resting state.

**Option A** (the QA key took Mason's slot). `8K81…` is still a devnet signer,
so QA's server works again at once. But the restored list names Mason, whom the
chain no longer seats. Either set the list back to what the chain holds (public
keys, so `config:set` is fine here):

```bash
heroku config:set --app turf-monster-qa \
  SOLANA_MULTISIG_SIGNERS="8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd,7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr,$QA_PUBKEY"
```

or seat Mason again with a reverse rotation, after which the restored list is
true: on `/admin/authorities`, slots `8K81…`, `7ZDJ…`, `CytJ…`, authorizers
`8K81…` (the QA server leads on its restored key) and `7ZDJ…`.

**Option B** (the QA key took Xan's slot). `heroku rollback` alone does **not**
recover QA: it restores `8K81…`, which is **no longer a devnet signer**, so every
admin instruction fails `Unauthorized`. Recovery needs a reverse rotation that
seats `8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd` again, chain first:

1. On `/admin/authorities` (turf-monster-qa, still on the QA key), enter slots
   `8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd`,
   `7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr`,
   `CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR`, and authorizers `7ZDJ…` (lead)
   and `CytJ…`, both Phantom signatures. The QA key cannot authorize it, because
   this rotation evicts it (6017). The page checks the same v0.25 rules as the
   dry run; `bin/qa-signer-rotation` cannot plan this one, because it refuses to
   seat production's key.
2. `bin/qa-signer-rotation --show` must list `8K81…` and not the QA key.
3. Then `heroku rollback <the release you noted> --app turf-monster-qa`. The
   restored list, `8K81…,7ZDJ…,CytJ…`, now matches the chain. QA is dead between
   steps 1 and 3; keep them close together.

**Option C** (v0.26, the QA key appended). `8K81…` is still a devnet signer, so
QA works again at once. The restored list omits the QA key, which the chain still
seats; set `SOLANA_MULTISIG_SIGNERS` to what `bin/qa-signer-rotation --show`
reads, as under option A.

## Step 9 — Verify QA

- The boot log carries one `[signer-isolation]` line. With step 10 already
  merged and deployed to QA it reads OK; on an older QA build it still warns
  "unfiled". Either way it must no longer say "holds production's system wallet".
- The guard itself, read-only, from a turf-monster checkout that has step 10.
  It must print the OK line and exit 0 even with enforcement forced:

  ```bash
  heroku config --json --app turf-monster-qa \
    | SIGNER_ISOLATION=enforce ruby lib/solana/signer_isolation.rb --environment qa; echo "exit=$?"
  ```
- `/admin/authorities` on QA names the new key as the server's signing identity.
- One routine devnet action succeeds, such as creating a test contest.

## Step 10 — File QA's public key (DONE, ahead of the flip)

`qa.system_wallet` in `config/solana_signers.yml` is
`2eGs8G3wzhEeNQQU2Q86BmmA2xTpDbMMae3Y1bvpZfx9` (task `turf-qa-gets-own-signer`).
It was filed before step 8 so that the flip needs no further PR. Until step 8
runs, the guard therefore reports two findings for qa, in warn mode: QA holds
production's wallet, and QA's key is not its filed wallet. After step 8, and
once QA runs a build that carries the filing, the boot line reads OK, and the
next `bin/deploy` pre-flight prints an OK line for both apps.

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
| `bin/deploy` pre-flight, when `config/solana_signers.yml` is missing, not YAML, or the wrong shape | either | refuses (exit 4): the file is where `enforce` is committed, so an unreadable one cannot prove warn. A guard that crashes on a readable file still only warns |
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
