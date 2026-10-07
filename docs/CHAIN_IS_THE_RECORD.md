# The Chain Is The Record

**Status: proposed, awaiting Alex's review.** Nothing on this page is built yet
unless it says "today". It is the design for epic `platform-audit-refactors`,
piece 5h, task `chain-is-the-record-design`.

**The principle.** The database holds pointers; the chain holds money. The UI may
run ahead of the chain for style, never for truth. A number of dollars that the
app shows is either read from chain or labelled as pending.

Code is cited by path and symbol, never by line. On-chain claims are read from
`turf-vault` at `v0.25.0` (deployed on both clusters, per
`turf-vault/docs/CURRENT_DEPLOYMENT.md`) and at `origin/main` (the source, crate
`0.26.0`, not deployed). Where the two differ, the page says which one it means.

## 1. Alex's decisions

1. **The vault is a vault and nothing more.** It holds no contest state and no
   picks: no scores, no standings, no selections. It holds the escrow (prize pool,
   fees, the contest's open, settled or cancelled status) and these facts, fixed
   when written:
   - the entries, and when each joined; join order breaks ties;
   - the payout structure as a rank schedule: rank 1..n in base units, written at
     contest creation and never changed. Settlement supplies only a ranked list of
     entries; the program pays by rank and refuses anything else;
   - the identifiers that tie an entry to a wallet (section 3).
2. **`TransactionLog` stays, as a Turf-only pointer ledger:** signature, kind,
   wallet, entry or contest, and no amounts. It is not an engine primitive. If a
   second app ever needs on-chain pointers, it moves to `solana-studio`.
3. **No refunds on cancel or withdrawal.** An entrant who leaves forfeits the fee.
   The `entry-forfeit` SOP stands.
4. **Settlement execution policy is open.** Section 5 lays out the options.

## 2. What exists today

**On chain (`v0.25.0`, deployed).**
- `Contest` (`programs/turf_vault/src/state.rs`) already carries the rank schedule:
  `payout_amounts: Vec<u64>`, at most `MAX_PAYOUT_TIERS` (10).
  `handle_create_contest` requires its sum to equal `prize_pool`, and no other
  instruction writes the field, so it is immutable after create.
- `handle_settle_contest` does **not** read `payout_amounts`. It takes
  `Settlement { wallet, entry_num, rank, payout }` rows chosen by the caller and
  checks only that payouts sum to no more than `contest.prize_pool`, that no
  `(wallet, entry_num)` repeats, that each entry PDA is `Active`, that each payout
  goes to the winner's canonical USDC ATA, and that the lock or conclusion time
  has passed. Today the signers decide who gets what; the schedule does not bind.
- Settle needs two of the three `VaultState` signers: `validate_multisig(admin,
  cosigner)` in `v0.25.0`. On `origin/main` the threshold becomes data
  (`GovernanceConfig`), and `DEFAULT_THRESHOLDS` sets `SETTLE_CONTEST` to **three**.
- `ContestEntry` holds `contest_id`, `wallet`, `entry_num`, `status`, `rank`,
  `payout`, `currency_idx`, and 16 reserved bytes. **It records no join order.**
  `Contest.current_entries` counts entries but no entry keeps its position.
- Entry fees never reach the prize pool: `handle_enter_contest` sends them to the
  operator-revenue ATA. `cancel_contest` returns the prize pool to the creator.
  No instruction pays an entrant back, which is why decision 3 is free on chain.
  `close_contest` sweeps any prize-pool residue (an unpaid place on a short fill)
  to operator revenue.

**In Rails (`accepted`).**
- **Formats fit one settlement** (contest-formats-fit-one-settlement).
  `Contest::MAX_PAID_RANKS` is 4; `Contest#payout_table_cents` is snapshotted on
  create (`snapshot_payout_table`, `attr_readonly`) and is what
  `Contest#onchain_params` writes as `payout_amounts`. `Solana::Vault#assert_settle_fits_one_packet!`
  names the failure if a table ever outgrows one transaction.
- **Ties** (`Contest::PayoutSplit`): entries order by score, then `entries.id`.
  A tie inside the paid ranks pools the tied places' prizes and splits them; a tie
  at the last paid rank pays the earliest entry alone.
- **Settle is built before the contest reads settled.** `Contest#grade!` ranks,
  writes `rank` and `payout_cents`, writes `TransactionLog` payout credits with
  `amount_cents`, calls `settle_onchain!` (which queues a `settle_contest`
  `PendingTransaction`), then sets `status: "settled"`. A failed build rolls the
  grade back. But `settled` means *queued*, not *paid*:
  `Admin::PendingTransactionsController#verify_and_record_cosign!` flips the
  separate `onchain_settled` flag only after a cosign lands.
- **Grade refuses a cancelled contest** (grade-refuses-cancelled-contests):
  `Contest#grade!` raises `CancelledContestError` before any write.
- **Reconcile is chain-first** (reconcile-cancelled-contest-34):
  `Contests::CancellationReconciler` reads the `Contest` status byte and the prize
  pool balance before writing `onchain_cancelled`, and fails closed.
- **Money is integers** (turf-money-in-integer-units):
  `Solana::Config.cents_to_base_units` takes only an Integer; one cent is
  `BASE_UNITS_PER_CENT` (10,000) base units.
- **The frozen-account guard** (`FrozenAccount`, `FrozenAccountGuard`,
  `FrozenAccount::Validation`) is an app-level hold. It stops the app acting for
  a frozen account; it does not touch funds, and settlement does not consult it.
- **Paying wallet.** `settle_onchain!` reads `entry.user.solana_address`. The
  entry row stores no wallet, yet the entry PDA's seeds are the wallet that paid.
  A user who changes wallet after entering gets a settle the program rejects.
- **Sweeps.** `PendingTransactionSweeperJob` flips `enter_contest_direct` rows
  older than an hour to `failed` by age, without asking the chain. Treasury rows
  (settle, cancel) have no sweep at all. `Entries::OnchainReconcileJob` heals one
  stranded entry when enqueued; it is not on `config/schedule.yml`.
- **Balances** come from chain already: the navbar reads cached USDC and USDT
  balances with a 60-second TTL (`docs/SOLANA.md`, "Navbar Balance").

## 3. What the vault records, and what Rails points at

| Fact | Lives on chain | Rails keeps |
|------|----------------|-------------|
| Contest identity | `Contest.contest_id` = SHA256(slug); PDA `[contest, contest_id]` | `slug`, `onchain_contest_id` (PDA) |
| Rank schedule | `Contest.payout_amounts`, base units, fixed at create | `payout_table_cents`, a display copy that must equal it |
| Prize pool | `prize_pool` PDA balance | nothing |
| Escrow status | `Contest.status` (Open, Settled, Cancelled) | `status` mirror, set only from a chain read |
| Entry identity | PDA `[entry, contest_id, wallet, entry_num]` | `onchain_entry_id`, `entry_number`, **paying wallet (new)** |
| Join order | **`ContestEntry.join_seq` (new)** | nothing; ties read it |
| Result | `ContestEntry.rank`, `payout`, `status` | `rank`, `payout_cents` as the proposal until confirmed |
| Picks, scores | never | `selections`, `score` |
| Movements | the transactions themselves | `TransactionLog`: signature, kind, wallet, entry or contest |

**The identifiers an entry needs, and no more:** `contest_id`, `wallet`,
`entry_num` (the three PDA seeds), and `join_seq`. The user PDA `[user, wallet]`
and the payout ATA are derived from `wallet`; `currency_idx` stays as the record of
what paid the fee. Nothing ties an entry to a Turf user id on chain.

## 4. Settlement lifecycle

1. **Grade proposes.** `Contest#grade!` scores, ranks by score then `join_seq`,
   writes each entry's `rank` and proposed `payout_cents`, queues the settle
   transaction, and sets the contest to **`settlement_pending`**. It writes no
   amount to `TransactionLog` and sends no email.
2. **The settle transaction carries only a ranked list** of `(wallet, entry_num)`.
   The program pays `payout_amounts[i]` to position `i`. A list longer than the
   schedule, an entry not `Active` in this contest, or a repeat is refused, so
   the sum cannot exceed the pool and the amounts cannot be chosen by a signer.
3. **Settled means confirmed.** `settled` is set only after the settle transaction
   confirms and a chain read shows `Contest.status == Settled`. Winner emails
   (`Contest#notify_winners!`) follow that read, as they do today.
4. **Failure leaves the proposal visible.** A rejected, expired or ambiguous
   broadcast keeps the contest `settlement_pending` with its ranks shown and
   marked unpaid; the `PendingTransaction` broadcast seam
   (`claim_for_broadcast!`, `reconcile_broadcast!`) decides whether a rebuild is
   safe, as it does today.
5. **A scheduled chain sweep reconciles.** One job reads the chain for every
   `submitted` entry and every `settlement_pending` contest and moves each row to
   what the chain says. It replaces the age-based flip in
   `PendingTransactionSweeperJob`; age only decides when to look, never what to
   write.
6. **Displays read chain.** Balances, prizes and winnings come from chain reads
   cached about a minute, the pattern the navbar already uses. Rails' copies
   (`payout_cents`, `payout_table_cents`) render only as "pending" or as labels.

**Ties under a rank schedule.** The program pays each place its own amount, so a
tie cannot pool places on chain. Join order breaks every tie, inside the paid
ranks as well as at the last one. This changes `Contest::PayoutSplit`, which pools
and splits today; Alex confirms it in review.

## 5. Settlement execution: the open question

Today settle needs two of three signers: the server key (Xan, `8K81…`) signs when
it builds, and Alex's Phantom (`7ZDJ…`) cosigns at `/admin/pending_transactions`.
The half-signed legacy transaction expires with its blockhash (about 60 to 90
seconds), and `Admin::PendingTransactionsController#rebuild` mints fresh bytes for
another try. The third signer is Mason (`CytJ…`). Xan and Mason are the hub's two
parked admin identities.

**(a) Durable nonce: Alex cosigns once, the server submits and retries.**
The settle anchors on a nonce account instead of a blockhash, so Alex's signature
never expires; the server resubmits until it lands. `solana-studio` has the
pieces (`Solana::NonceAccount`, `Solana::SystemProgram.advance_nonce_account`).
- Trust: Alex approves exact bytes; the server can only send those bytes.
- Blocker: a nonce transaction is recognised only when `advanceNonceAccount` is
  instruction 0, and Phantom injects Lighthouse instructions ahead of it. The
  `Solana::Cosign` module header, `Solana::Vault#build_enter_contest` and
  `docs/SOLANA.md` record this, and no Phantom-signed builder uses a nonce. So (a)
  needs Alex to cosign with a signer that does not rewrite the transaction (CLI
  or hardware wallet), plus one nonce account per settlement in flight.
- A settle that lands and fails on chain still needs a new cosign.

**(b) Automatic settlement by two agent-held keys.** The server signs with Xan
and Mason; no human is in the loop.
- Trust: a captured pair can settle any contest whose lock has passed. With the
  rank schedule on chain, the worst it can do is pay the fixed prizes, in a wrong
  order, to entries in that contest. Without the schedule it can pay the whole pool
  to one entry. So (b) is safe only after the vault upgrade in section 6.
- Cost: `v0.26` sets `SETTLE_CONTEST` to three ("anything that moves money needs
  three"). (b) needs Alex to lower it to two, which `set_action_threshold` allows
  (the floor is one) with three signatures. It reverses a stated design rule for
  this one action. It also requires the two keys to sit on separate hosts.

**(c) Today's flow, rebuild and recosign on every failure.**
- Trust: strongest; Alex sees every settlement.
- Cost: every expiry or RPC fault costs Alex another session, and winners wait on
  him. Nothing changes on chain.

**Recommendation: (b), switched on only once the rank-schedule upgrade is live,
with (c) until then.** With the schedule binding, settlement stops being a money
decision and becomes a ranking decision, and a human cosign adds little a chain
sweep and a visible proposal do not. (a) waits on a wallet investigation the repo
already records as unsolved. Alex decides, and also decides whether a frozen
account's winning entry is paid (the program pays by rank and cannot see a
freeze).

## 6. Vault program changes for the next upgrade

Each is a future task. They ride with or after the pending `v0.26` window, and
each re-pins `EXPECTED_IDL_HASH`.
- **Vault settles by ranked entries:** `settle_contest` takes `(wallet, entry_num)`
  in rank order and pays from `payout_amounts`; it drops caller-supplied `rank`
  and `payout`.
- **Vault records entry join order:** `join_seq: u32` set from
  `current_entries` in both `handle_enter_contest` and `handle_enter_contest_with_token`,
  carved from `ContestEntry._reserved` so account size does not change.
- **Vault rank schedule stays fixed at create:** keep `payout_amounts` with no
  writer after `handle_create_contest`, and add a test that proves it.

## 7. Rails changes

Each is a future task title.
- **Contest grades to settlement pending**: a `settlement_pending` status;
  `settled` only on a confirmed chain read.
- **Entry stores its paying wallet**, and settle reads it, not the user's wallet.
- **Chain sweep reconciles entries and settlements**, replacing the age-based
  `PendingTransactionSweeperJob` flip.
- **Transaction log holds pointers only**: drop `amount_cents` and
  `balance_after_cents` from new writes; add signature, kind, wallet and target.
- **Ties break by join order** in `Contest::PayoutSplit`.
- **Money displays read cached chain** for prizes and winnings.
- **Terms match no refunds**: `pages/terms.html.erb` (`#refunds`) still promises
  an entry-fee refund for a contest cancelled before it locks. Decision 3 needs
  that copy changed; it is Alex's call.
- **Settle builder sends ranked entries**, after the vault upgrade.
- **Settlement executor**, per the option Alex picks.

## 8. Not verified

- That Phantom inserts Lighthouse instructions when signing a vault cosign (as
  opposed to an entry). This page relies on the repo's own record of it.
- Where Mason's private key is held, and whether an agent can reach it today.
- That a durable-nonce transaction which fails on chain still advances its nonce
  (Solana runtime behaviour, not tested here).
- That no deployed contest's on-chain `payout_amounts` differs from its Rails
  `payout_table_cents`; it needs a chain read per contest.

## Decision log

- 2026-10-05 — Alex: money in the Turf database is superficial; the chain is the
  record.
- 2026-10-06 — Alex: contest payouts standard 300/100/50/50, large
  1000/400/200/200; a tie at the last paid rank goes to the earliest entry.
- 2026-10-06 — Alex: the vault holds no contest state and no picks; on chain are
  the entries, their join order, a rank schedule fixed at create, and the
  identifiers tying an entry to a wallet. `TransactionLog` stays as a Turf-only
  pointer ledger. No refunds; leaving forfeits the fee. Settlement execution
  policy is open; this page presents the options.
