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
| `seed` | Nothing. Run once per QA database | `STOPPED — the roster seed could not save …` |
| `create` | A user on `team@mcritchie.studio` (the `seed` step writes it) and the slate `NFL 2026 Preseason Weeks 3-4`. Both are read before anything is written | `STOPPED — no user on team@mcritchie.studio …` |
| `create` | The server key holds the prize pool in devnet USDC, or is the test mint's authority | `STOPPED — the server key … and the mint failed` |
| `enter` | Each cast wallet (`mason`, `mack`, `turf`, 1Password `studio-agents`) holds the entry fee in devnet USDC or an entry token | `FAILED · …` beside that player; the others still enter |
| `play` | ESPN answers for preseason weeks 3 and 4 (`Driver::POLL_SLOTS`) | `the ESPN poll failed for slot …` |
| `conclude` | The server key is a devnet `VaultState` signer, and so is the co-signer wallet the Treasury page names | The Co-sign click fails `Unauthorized` on the page |
| `close` | The contest has settled on chain (or was cancelled). Read before the close is sent | `STOPPED — contest … has not settled on chain` |

`seed` writes the rows `User::PARKED_IDENTITIES` describes, through
`db/seeds/users.rb`, and no other row. The creator row holds its parked wallet,
so its address is proven the way `docs/AUTH.md` ("Parked roles") requires.

`create` prints the key the server signs as and the co-signer the settle
transaction will name. The server key is `SOLANA_ADMIN_KEY` on the dyno.

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
