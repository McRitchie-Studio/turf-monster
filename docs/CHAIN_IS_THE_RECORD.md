# The Chain Is The Record

**Status: proposed; the settlement execution path is decided.** Nothing on this
page is built yet unless it says "today". It is the design for epic
`platform-audit-refactors`, piece 5h, task `chain-is-the-record-design`; task
`settlement-uses-durable-nonce` records the settlement decision.

**The principle.** The database holds pointers; the chain holds money. The UI may
run ahead of the chain for style, never for truth. A number of dollars that the
app shows is either read from chain or labelled as pending.

Code is cited by path and symbol, never by line. On-chain claims are read from
`turf-vault` at `v0.25.0` (deployed on both clusters, per
`turf-vault/docs/CURRENT_DEPLOYMENT.md`) and at `origin/main` (the source, crate
`0.26.0`, not deployed). Where the two differ, the page says which one it means.

## 1. Alex's decisions

Every decision Alex has made on this subject, in one list. Dates are in the
decision log at the end.

1. **The chain is the record.** Money in the Turf database is superficial.
2. **The vault is a vault and nothing more.** It holds no contest state and no
   picks: no scores, no standings, no selections. It holds the escrow (prize pool,
   fees, the contest's escrow status) and these facts, fixed when written:
   - the entries, and when each joined;
   - the payout structure as a rank schedule: rank 1..n in base units, written at
     contest creation and never changed. Settlement supplies only a ranked list of
     entries; the program pays by rank and refuses anything else;
   - the identifiers that tie an entry to a wallet (section 3).
3. **Payouts.** Standard pays 300/100/50/50 dollars, large pays 1000/400/200/200.
   A tie at the last paid rank goes to the earliest entry. *Proposed, not yet
   decided:* join order breaks every tie, inside the paid ranks too (section 4).
4. **`TransactionLog` stays, as a Turf-only pointer ledger:** signature, kind,
   wallet, entry or contest, and no amounts. It is not an engine primitive. If a
   second app ever needs on-chain pointers, it moves to `solana-studio`.
5. **No refunds on cancel or withdrawal.** An entrant who leaves forfeits the fee.
   The `entry-forfeit` SOP stands.
6. **Settlement uses a durable nonce.** Alex cosigns a settle transaction once;
   the server submits and retries those signed bytes until they land. One
   prerequisite is open: a cosigner that keeps instruction order (section 5).

## 2. What exists today

**On chain (`v0.25.0`, deployed).**
- `Contest` (`programs/turf_vault/src/state.rs`) already carries the rank schedule:
  `payout_amounts: Vec<u64>`, at most ten entries (`#[max_len(10)]` on the field).
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
  operator-revenue ATA. `cancel_contest` returns the prize pool to the creator,
  and `close_contest`, on a settled or cancelled contest, sweeps any prize-pool
  residue (an unpaid place on a short fill) to operator revenue. No instruction pays an entrant
  back, which is why decision 5 is free on chain.
- `Contest.status` is one of `Open`, `Locked`, `Settled`, `Cancelled`. `Locked`
  is vestigial: no instruction sets it, and a contest's lock is its
  `lock_timestamp`.
- Entry tokens are cheap to mint. `mint_entry_token` takes one vault signer and no cap on
  `v0.25.0`; on `origin/main` `DEFAULT_THRESHOLDS` keeps `MINT_ENTRY_TOKEN` at one
  inside a window cap (`DEFAULT_MINT_WINDOW_CAP`, 250 a day) and asks three above
  it. A token pays for an entry through `handle_enter_contest_with_token`.

**In Rails (`accepted`).**
- **Formats fit one settlement** (contest-formats-fit-one-settlement).
  `Contest::MAX_PAID_RANKS` is 4; `Contest#payout_table_cents` is snapshotted on
  create (`snapshot_payout_table`, `attr_readonly`) and is what
  `Contest#onchain_params` writes as `payout_amounts`. `Solana::Vault#assert_settle_fits_one_packet!`
  names the failure if a table ever outgrows one transaction. A contest whose
  table has more than `MAX_PAID_RANKS` ranks is invalid on create
  (`Contest#payout_table_settles`); the create and bundle endpoints answer 422
  with the reason before a transaction is built.
- **Contests that opened with a longer table.** `bin/rails contests:payout_census`
  (SELECT only) lists every unsettled contest whose table is over the limit or
  missing. `TABLE_CENTS=… bin/rails "contests:reshape_payout[slug]"` replaces one
  unsettled contest's table: it is a dry run without `WRITE=1`, and it refuses a
  table over the limit or one whose sum differs from the contest's prize pool.
- **Ties** (`Contest::PayoutSplit`): entries order by score, then `entries.id`.
  A tie inside the paid ranks pools the tied places' prizes and splits them; a tie
  that straddles the last paid rank pays the earlier entries, in join order
  (`entries.id`), so a tie exactly at the last paid rank pays the earliest entry
  alone.
- **Grade proposes; a confirmed settle settles** (`Contest::Settlement`).
  `Contest#grade!` ranks, writes `rank` and `payout_cents`, and calls
  `settle_onchain!`, which queues a `settle_contest` `PendingTransaction`. The
  contest then reads `settlement_pending`; a failed build rolls the grade back,
  and a second grade is refused. `settled` is written only by
  `Contest#mark_settled!`, which takes the confirmed signature and is called
  from the operator's cosign
  (`Admin::PendingTransactionsController#verify_and_record_cosign!`) and from
  the sweep (`Contests::SettlementReconciler`). An off-chain contest, and one
  where no entry won a prize, owes nothing on chain and settles at grade.
- **A settle that does not pay stays visible.** A settle that lands and fails,
  expires, or is refused before the send returns its row to `pending` for a
  rebuild and writes the reason to `contests.settlement_error`; the contest
  stays `settlement_pending`, and the contest page and the cosign queue show
  the reason.
- **Payout ledger rows are pointers.** `mark_settled!` writes one
  `TransactionLog` payout row per paid entry, carrying the settle signature
  and no amount. Every other ledger type still records `amount_cents`.
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
- **Settle pays the entering wallet.** `Contest#payout_settlements` pays each
  entry at `Entry#wallet_address`, the wallet whose seeds derive its entry PDA.
  A paid entry with no recorded wallet refuses the grade; none is dropped.
- **Sweeps.** `Entries::PaymentSweepJob` settles every entry whose payment is
  `submitted` from the chain, every two minutes (`Entry::Payment`,
  `Entries::PaymentSettlement`). It also reads an abandoned row that still
  holds the in-flight key (a clear that raced its payment): the row is made a
  cart again at the slot its prepared wire names, then settled; one with no
  such wire is left and named in the log (`cleared_unrestored=`).
  `Contests::SettlementSweepJob` does the same
  for every `settle_contest` row left `submitted`, every two minutes
  (`Contests::SettlementReconciler`). Neither moves a row by its age alone. A
  settle row returns to the cosign queue only when its contest account reads
  Open or Locked at `finalized` (`PendingTransaction#settle_rewind_hold`): a
  Settled account settles the contest, and an absent, unreadable or
  otherwise-read account changes nothing. The
  other treasury rows (cancel, currency, revenue sweep) have no sweep.
  `Entries::OnchainReconcileJob` heals one stranded entry when enqueued; it is
  not on `config/schedule.yml`.
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
4. **Failure leaves the proposal visible.** Until the settle lands, the contest
   stays `settlement_pending` with its ranks shown and marked unpaid. On a
   nonce-anchored settle (section 5) the server resends the same signed bytes
   rather than rebuilding; it asks Alex for a new cosign only when the settle
   landed and failed or the nonce was consumed. The `PendingTransaction`
   broadcast seam (`claim_for_broadcast!`, `reconcile_broadcast!`) records each
   attempt, as it does today.
5. **A scheduled chain sweep reconciles.** One job reads the chain for every
   `submitted` entry and every `settlement_pending` contest and moves each row to
   what the chain says. `Entries::PaymentSweepJob` is the entry half and
   `Contests::SettlementSweepJob` the settlement half; age only decides when to
   look, never what to write.
6. **Displays read chain.** Balances, prizes and winnings come from chain reads
   cached about a minute, the pattern the navbar already uses. Rails' copies
   (`payout_cents`, `payout_table_cents`) render only as "pending" or as labels.

**Ties under a rank schedule.** The program pays each place its own amount, so a
tie cannot pool places on chain. Join order breaks every tie, inside the paid
ranks as well as at the last one. This changes `Contest::PayoutSplit`, which pools
and splits today; Alex confirms it in review.

## 5. Settlement execution: a durable nonce

**Today.** Settle needs two of three signers. `Solana::Vault#build_settle_contest`
signs first as the server key (Xan, `8K81…`) on a fresh recent blockhash, and
Alex's Phantom (`7ZDJ…`) cosigns at `/admin/pending_transactions`. The half-signed
legacy transaction expires with its blockhash (about 60 to 90 seconds), and
`Admin::PendingTransactionsController#rebuild` mints fresh bytes for another try.
The third signer is the key `turf-vault/docs/CURRENT_DEPLOYMENT.md` names "Mason
signer" (`CytJ…`); who holds it is in section 8.

**The decision (a): Alex cosigns once, the server submits and retries.** The
settle anchors on a nonce account instead of a recent blockhash: its
`recentBlockhash` is the nonce account's stored value, and
`SystemProgram.advanceNonceAccount` is instruction 0. The signed bytes stay valid
until that nonce advances, so Alex signs once and the server resends the same
bytes until they land.
- **Trust.** Alex approves exact bytes. The server can send only those bytes; it
  cannot change a winner, an amount or an order without a new signature from him.
- **The pieces that exist.** `solana-studio` has `Solana::NonceAccount` (parse a
  nonce account, `initialized?`, `nonce`) and `Solana::SystemProgram`
  (`create_account`, `initialize_nonce_account`, `advance_nonce_account`,
  `withdraw_nonce_account`, `authorize_nonce_account`). In turf,
  `Solana::Vault#build_tx` takes `durable_nonce:` and prepends the advance, and
  `durable_nonce_config` reads one nonce account from
  `SOLANA_DURABLE_NONCE_PUBKEY` with the server key as its authority.
  It has no caller since 2026-10-07. Its last one was
  `Solana::Vault#build_create_contest` on its `admin_signs: true` branch,
  reached from `ContestsController#prepare_onchain_contest`: admin-first plus
  Phantom cosign, the same shape settle has today. That route is retired and the
  branch takes a fresh blockhash (retire-nonce-contest-prepare). No settle
  builder passes a nonce.
- **What does not carry over.** `Solana::Cosign` is built without a nonce, and
  `Solana::Cosign::Expectation` refuses a nonce advance among the instructions it
  compares. The settle path builds and verifies its own wire.
- **A settle that lands and fails on chain** still needs a new cosign: the nonce
  has advanced (section 8), so the signed bytes are dead.
- **On `v0.26`** `SETTLE_CONTEST` asks three signatures, so a settle carries the
  server key, Alex, and a third signer. Each signs the same nonce-anchored bytes
  once.

**The open prerequisite: a cosigner that keeps instruction order.** A nonce
transaction is recognised only when `advanceNonceAccount` is instruction 0, and
Phantom may insert Lighthouse instructions ahead of whatever was built. When one lands
ahead of the advance, validators read the nonce value as an unknown blockhash and
reject the transaction. The repo records this in the `Solana::Cosign` module
header, the durable-nonce note in `Solana::Vault#build_enter_contest`, and
`docs/SOLANA.md` (the 2026-06-11 mainnet incident). So (a) needs Alex to cosign
with a signer that signs the message as built: a CLI keypair or a hardware
wallet. Choosing that signer, and seating it as a vault signer if it is a new
key, is Alex's to decide before any settle runs on a nonce. Until then, settle
runs as today. Whether Phantom also rewrites a transaction that already carries
the server's signature is not verified (section 8).

**Considered and not chosen.**
- **(b) Automatic settlement by two agent-held keys.** No human in the loop. A
  captured pair can enter wallets it controls before lock, paying with entry
  tokens it mints (one signer, section 2) or its own USDC, then rank those
  entries first, so the rank schedule does not bound the loss. The exposure is
  every contest neither full nor locked; on `origin/main` the pair can also push
  a lock later before it passes (`SET_CONTEST_LOCK_TIME` defaults to 2;
  `SET_CONTEST_LOCK_TIME_REOPEN`, for a passed lock, to 3). Only a program-enforced pool cap bounds it, and it narrows
  `v0.26`'s rule that moving money needs three signatures.
- **(c) Today's flow, rebuild and recosign on every failure.** Strongest trust,
  but every expiry or RPC fault costs Alex another session and winners wait on
  him.

Alex also decides whether a frozen account's winning entry is paid: the program
pays by rank and cannot see a freeze.

## 6. Vault program changes for the next upgrade

Each is a future task. They ride with or after the pending `v0.26` window, and
each re-pins `EXPECTED_IDL_HASH`.
- **Vault settles by ranked entries:** `settle_contest` takes `(wallet, entry_num)`
  in rank order and pays from `payout_amounts`; it drops caller-supplied `rank`
  and `payout`.
- **Vault records entry join order:** `join_seq: u32` set from
  `current_entries` in both `handle_enter_contest` and `handle_enter_contest_with_token`,
  carved from `ContestEntry._reserved` so account size does not change. Entries
  made before the upgrade read `join_seq` as 0, so a tie among them still falls
  back to Rails' `entries.id` order.
- **Vault settles the full schedule:** the ranked list's length must equal
  `min(payout_amounts.len(), active entries)`.
- **Vault rank schedule stays fixed at create:** keep `payout_amounts` with no
  writer after `handle_create_contest`, and add a test that proves it.

## 7. Rails changes

Each is a task title; the ones marked built are in the code.
- **Contest grades to settlement pending** (built, `Contest::Settlement`): a
  `settlement_pending` status; `settled` only on a confirmed chain read.
- **Entry stores its paying wallet**, and settle reads it, not the user's wallet
  (filed as `settle-pays-the-entering-wallet`).
- **Chain sweep reconciles entries and settlements** (built). Entries:
  `Entries::PaymentSweepJob`. Settlements: `Contests::SettlementSweepJob`.
- **Transaction log holds pointers only**: drop `amount_cents` and
  `balance_after_cents` from new writes; add signature, kind, wallet and target.
  Payout rows are pointers already; the other types still carry amounts.
- **Ties break by join order** in `Contest::PayoutSplit`.
- **Money displays read cached chain** for prizes and winnings.
- **Terms match no refunds**: `pages/terms.html.erb` (`#refunds`) still promises
  an entry-fee refund for a contest cancelled before it locks. Decision 5 needs
  that copy changed; it is Alex's call.
- **Settle builder sends ranked entries**, after the vault upgrade.

The durable-nonce settlement (section 5) is four more:
- **Settlement holds its own nonce account**: one nonce account per settlement in
  flight, created and initialised with the server key as authority, recorded on
  the settle `PendingTransaction`, and withdrawn once the settlement is final.
  The single `SOLANA_DURABLE_NONCE_PUBKEY` account stays with contest create.
- **Settle advances the nonce first**: `build_settle_contest` anchors on that
  account with `advanceNonceAccount` as instruction 0, and the verify step
  refuses a returned wire with any instruction ahead of it. The packet check
  (`assert_settle_fits_one_packet!`) counts the advance.
- **Settlement retries until it lands**: a loop that resends the same signed
  bytes and reads the signature's status before every resend; it stops on a
  landed success, a landed failure, or a consumed nonce, and never rebuilds.
- **Settlement handles a consumed nonce**: when the nonce account's value no
  longer matches the signed bytes and the settle signature never landed, another
  transaction used the nonce; the row goes to "needs a new cosign" and Rails
  reads the contest from chain before asking for one.

## 8. Not verified

- That Phantom puts Lighthouse instructions ahead of the advance when it cosigns a
  vault transaction the server has already signed (the shape of settle and of
  `build_create_contest`'s retired nonce branch), as opposed to the entry transaction the
  2026-06-11 incident was on.
  This page relies on the repo's own record of the 2026-06-11 incident. If
  Phantom leaves a pre-signed wire's order intact, the prerequisite in section 5
  may not apply to it; that needs a devnet test before anyone relies on it.
- That a CLI or hardware signer leaves instruction order intact. It is the
  expected behaviour of a signer that signs the message bytes it is given, and it
  is untested here.
- Whether `SOLANA_DURABLE_NONCE_PUBKEY` is set in production. Nothing reads it
  since `ContestsController#prepare_onchain_contest` and its route were retired
  (2026-10-07).
- Who holds the `CytJ…` key, and whether it can sign a nonce-anchored settle
  without reordering it. It matters for the third signature `v0.26` asks of every
  settle; if it is a Phantom, it meets the same prerequisite as Alex's.
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
- 2026-10-06, 21:05 MDT — Alex: settlement uses a durable nonce (option (a)).
  He cosigns once; the server submits and retries that signed transaction until
  it lands. (b) and (c) are recorded as considered. The cosigner that keeps
  instruction order is the open prerequisite.
