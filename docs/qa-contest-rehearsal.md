# QA contest rehearsal: what it needs, and the operator's part

`bin/qa-contest-rehearsal` runs one contest on `turf-monster-qa` against devnet:
seed, create, enter, play, conclude, close. The step-by-step procedure is the
`contest-rehearsal` SOP in `mcritchie-studio`
(`docs/agents/agents/turf_monster/sops/contest-rehearsal.md`). This page states
what each step needs to be true on QA, and what Mr. McRitchie does at the
settlement.

Driver: `lib/turf_monster/qa_rehearsal/`. Tests: `test/lib/qa_rehearsal_*_test.rb`.

## What each step needs

| Step | Needs | Stops with |
|---|---|---|
| any | `turf-monster-qa` reports `SOLANA_NETWORK=devnet` and the devnet program id | `REFUSED — this driver only runs against devnet QA` |
| `seed` | Every row the seed would adopt is one it can prove ("What `seed` writes", below). Run once per QA database | `STOPPED — the roster seed would adopt … it cannot prove`, or `… could not save …` |
| `create` | A user on `team@mcritchie.studio` (the `seed` step writes it) and the slate `NFL 2026 Preseason Weeks 3-4`. Both are read before anything is written | `STOPPED — no user on team@mcritchie.studio …` |
| `create` | The server key is a signer in the devnet `VaultState`. Read from the chain before anything is written | `STOPPED — the server key … is not a signer in the devnet VaultState` |
| `create` | The server key holds the prize pool in devnet USDC, or is the test mint's authority | `STOPPED — the server key … and the mint failed` |
| `enter` | Each cast wallet (`mason`, `mack`, `turf`, 1Password `studio-agents`) holds the entry fee in devnet USDC or an entry token | `FAILED · …` beside that player; the others still enter |
| `play` | ESPN answers for preseason weeks 3 and 4 (`Driver::POLL_SLOTS`) | `the ESPN poll failed for slot …` |
| `conclude` | The server key is a devnet `VaultState` signer, and so is the co-signer wallet the Treasury page names | The Co-sign click fails `Unauthorized` on the page |
| `close` | The contest has settled on chain (or was cancelled). Read before the close is sent | `STOPPED — contest … has not settled on chain` |

`create` prints the key the server signs as and the co-signer the settle
transaction will name. The server key is `SOLANA_ADMIN_KEY` on the dyno.

### Before the first run

The steps do not check these, except where the table above says so:

- QA's `SeasonConfig.current_season_id` names a season that exists on devnet.
- QA's server key, `2eGs8G3wzhEeNQQU2Q86BmmA2xTpDbMMae3Y1bvpZfx9` after the
  signer change below, is a signer in the devnet `VaultState` and holds at
  least 500 devnet USDC.
- QA's `SOLANA_MULTISIG_SIGNERS` contains the co-signer wallet `7ZDJ…`.
- QA's `SOLANA_VAULT_GOVERNANCE` is off.

### What `seed` writes

`seed` runs `seed_parked_identities!(proven_only: true)` from
`db/seeds/users.rb` on the QA database. It writes:

- **The roster rows.** One row per `User::PARKED_IDENTITIES` entry, created or
  adopted, with the roster's email, name, username and role.
- **Their wallets.** Each roster row is left holding its parked wallet and no
  managed wallet. An identity the roster parks without a wallet (the house row,
  `turf`) has any wallet on its row cleared.
- **Usernames between roster rows.** A parked username held by another roster
  row moves to its owner. A username held by any other row stays where it is,
  and the seed prints that it left it.
- **Retired seats.** A row on a `User::RETIRED_IDENTITIES` address is demoted to
  the role that constant names. Nothing else on it changes.
- **Sessions.** A row that held a roster address unverified, with no other
  credential, has its sessions ended when the seed gives it a role or wallet.

No other row is written. The creator row holds its parked wallet, so its
address is proven the way `docs/AUTH.md` ("Parked roles") requires.

The seed adopts an existing row only when it can prove it, by the rule a
mailbox proof follows (`User#accept_mailbox_proof!`). It stops before any
write, naming each row by username, when a row it would adopt:

- holds a roster address unverified beside a wallet, a Google link or an API
  key, or
- matches a roster identity by username alone, with no row on that identity's
  address or wallet.

The seed changes neither row. An operator resolves each by hand on QA (clear
the other credential or the address; rename the username holder), then runs
`seed` again. `bin/rails users:parked_role_audit` lists the unproven holders.

### The server key after the QA signer change

`docs/qa-signing-key-rotation.md` moves QA's `SOLANA_ADMIN_KEY` to QA's own key.
The devnet test mint's authority does not move with it (that runbook, step 4),
so after the change `create` stops at the mint until the new key's USDC account
holds the pool ($500 on the standard tier) or the mint authority moves to it.

## The operator's part: the settlement co-signature

`conclude` grades the contest, builds the 2-of-3 `settle_contest` transaction
signed by the server, and prints a magic link. Nothing pays until the second
signature lands.

1. Open the **Magic Link** the step printed, in a desktop browser that has the
   Phantom extension. It signs you in as `alex@mcritchie.studio` and lands on
   **Treasury** (`/admin/pending_transactions`) on `qa.turfmonster.media`.
2. In Phantom, select the co-signer wallet the step printed (`7ZDJ…`). The
   **Co-signing wallet** panel at the top of the page shows the connected wallet.
3. Find the row **Settle Contest - QA Rehearsal …** with a **Pending** badge.
   It lists the settlement count and the total payout.
4. Press **Co-sign**. The page builds a fresh transaction at the click; there is
   no Rebuild button and no blockhash clock to race.
5. Phantom opens one approval for one transaction. Approve it. The server
   broadcasts and verifies it.
6. A **Settle Contest Confirmed** dialog appears. Press **Back to Treasury**.

It worked when:

- the row's badge reads **Confirmed** and carries a `TX:` link to the devnet explorer;
- the contest page reads settled, with each winner's payout beside their rank;
- on the explorer, the prize pool fell by exactly the sum paid and each winner's
  USDC rose by exactly their rank's payout.

If the dialog reports a failure, the row stays **Pending** and Co-sign may be
pressed again. A row that reads **Broadcast · unreconciled** is not pressed
again: press **Reconcile**.

Only after the row reads Confirmed does anyone run `bin/qa-contest-rehearsal close`.
Before that, `close` refuses and names the same two buttons.

### If the co-signature never comes

The contest stays `settlement_pending` and `close` keeps refusing. `close` also
accepts a cancelled contest, and the program's `cancel_contest` (2-of-3, the
prize pool returns to the creator) runs on a contest that is Open or Locked on
chain. The app queues that cancel only while the contest is `open` in the
database (**Cancel + refund creator** on the contest page, then a Co-sign on
Treasury), which is before `conclude` grades it. After `conclude`, the settle
co-signature is the one exit the app offers.
