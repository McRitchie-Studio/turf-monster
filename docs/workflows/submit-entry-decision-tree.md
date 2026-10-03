# Submit Entry — decision tree, failure points, and recovery channels

> **Code is law.** Every claim below cites `path/to/file.rb:NN` from the current
> codebase, and a bare `:NN` inherits the nearest preceding path — file context
> resets at each `##` heading. The number is bookkeeping; the SYMBOL beside it is
> the claim, and `test/docs/workflow_citation_docs_test.rb` reddens when a citation
> stops landing inside the definition its prose names. The ASCII trees stay
> uncited so they remain readable; the table under each one carries the citations
> for its branches.
> That symbol check reaches **77 of the 80 citations** here. The other **3** sit in
> code with no enclosing definition the guard can derive: one
> `lib/tasks/entries.rake` task body, plus **All 2 citations on
> `app/javascript/solana_utils.js`** — a `.js` file, where the guard reads no
> definitions at all because it parses only `.rb` and inline JS in `.erb`. Those ride
> the weaker LITERAL fallback: it proves the words the prose quotes are present in
> the cited lines, not that the code is. The symbol branch here is also WIDE in
> places: the `#enter` rows of §2 and every row of §3 land inside one long action
> (`#enter` is 176 lines, `#prepare_entry` 163, `#confirm_onchain_entry` 140), so a
> green row proves the number is inside the right action, not that it is on the
> right line — each was read against the code by hand on 2026-09-09, and the
> `Entries::ManagedEntry` and `Entries::ApiSubmission` rows (§2, §2a) on
> 2026-10-01, when that code was lifted out of `#enter`.
>
> **Cited since 2026-09-09.** Until then this document named its symbols and pointed
> at none of them, which made it invisible to the guard rather than weakly checked.
> The same pass corrected two branches of the §2 tree that the code had stopped
> taking — see the note under it.

Written 2026-06-11, the day the full web3 path was proven on mainnet (three
prod-only blockers fixed the same morning — see "Mainnet-only behaviors" at the
bottom). Source of truth: `ContestsController#enter`, `Entries::ManagedEntry`
(the gate-fund-confirm path `#enter` and the agent API share, since
2026-10-01), `Entries::ApiSubmission`, `#prepare_entry`,
`#confirm_onchain_entry`, `#recover_pending_entry`, `Solana::Vault`
(`cosign_expectation`, `cosign_and_broadcast_entry`), `Solana::Cosign::Expectation`,
`Entries::OnchainReconcileJob` / `OnchainReconciler`.

## 0. The one invariant everything serves

> **Money may only move AFTER every reversible check has passed, and once it
> moves, proof of payment must be durably persisted before anything else can
> fail.** Every failure mode below is judged against this: did funds move, and
> if so, where is the breadcrumb that lets us converge the entry to `active`
> without charging twice?

## 1. Client-side decision tree (the board, "Hold to Confirm")

```
Hold to Confirm
├─ logged in?                      no → auth modal (magic link / Google / wallet)
├─ eligibilityBlocker (client preflight — advisory only, server re-checks all)
│   ├─ has unconsumed entry token?            → token path is implied (web2)
│   ├─ usdcCents >= fee?                      → USDC
│   ├─ contest acceptsUsdt && usdtCents >= fee? → USDT fallback
│   └─ none of the above → blocked client-side ("insufficient funds" UX)
│      NOTE: null cents (RPC flake) FAILS OPEN — the server is authoritative.
└─ route by session mode ($store.session.mode)
    ├─ web3 (live Phantom signature this session) → POST prepare_entry  (§3)
    └─ web2 / managed wallet                      → POST enter           (§2)
```

| Branch | Where |
|---|---|
| guest → auth modal — `confirmEntry()` | `app/views/contests/_turf_totals_board.html.erb:1575-1580` |
| client preflight — the `eligibilityBlocker` export | `app/javascript/solana_utils.js:874`, mirrored onto `window` at `:962` |
| the blocker, re-checked inside `confirmEntry()` at submit time | `app/views/contests/_turf_totals_board.html.erb:1585-1589` |
| route by session — `useOnchainFlow = sess.isWeb3 && this.contestOnchain` in `confirmEntry()` | `:1631`, branch taken at `:1645` |

Currency pick (web3): USDC-first, USDT only when the contest's `accepts_usdt`
is true (contests created before 2026-06-11 are USDC-only forever — their
on-chain `entry_fee_by_currency[1]` is zero and immutable).
`ContestsController#prepare_entry` enforces it server-side
(`app/controllers/contests_controller.rb:990-1000`).

## 2. Web2 / managed path — `POST enter` (server signs, synchronous)

```
enter
├─ contest cancelled?            → 422 (terminal)
├─ user self-custodied?          → 422 + self_custodied flag (client routes to Phantom; server MUST NOT auto-sign)
├─ cart entry exists?            → no → error (survivor contests auto-create)
├─ onchain_session?              → 422 "use prepare_entry" (a wallet session
│                                   never enters here — it signs its own tx)
├─ self-custody account, web2 session? → 422 + web3_step_up_required blocker
└─ Entries::ManagedEntry#call    (the SAME path the agent API takes — §2a)
   contest.with_lock              (serialized per contest)
    ├─ assert_enterable!          ← ALL read-only gates BEFORE any spend:
    │     picks == 6, no started games, lock time, contest full,
    │     per-user entry limit, duplicate combo
    ├─ season configured?         → raise (clear msg, not a cryptic Anchor error)
    ├─ paid contest but no on-chain PDA? → refuse (no payment rail = no entry)
    └─ PAYMENT BRANCH
        ├─ managed wallet + has unconsumed token
        │    → enter_contest_with_token   ★ IRREVERSIBLE: atomic consume + entry + seeds
        │      (no USDC moves — the token IS the payment; cache busted after)
        ├─ managed wallet, no token, USDC allowed by the caller (the browser:
        │  AppFlags.web2_usdc_entry? on; the API: that AND allow_usdc)
        │    → balance pre-check, then enter_contest_with_usdc (server signs
        │      with the encrypted keypair)   ★ IRREVERSIBLE: USDC transfer
        │      (USDT in the web2 path is a phase-2 task — web3 only today)
        └─ neither → raise "No entry tokens. Buy at /tokens/buy"
─ durable capture (OUTSIDE the lock): entry.update!(onchain_tx_signature,
  onchain_entry_id) — the paid-proof survives anything that fails after this
─ ManagedEntry#finalize! → Entry#confirm! (re-runs the same gates as backstop)
    ├─ success → entry active, chat announce, seeds/token client fanout
    └─ TRANSIENT failure after the spend → entry stays `cart` WITH signature
         → Entries::OnchainReconcileJob.perform_later(entry.id)   (§5.2)
```

**Two branches of this tree were wrong until 2026-09-09.** It showed `enter`
verifying a wallet-signature proof for an `onchain_session?`; `enter` has refused
such a session outright since that unreachable branch was deleted. And it showed
the no-token branch as an unconditional `enter_contest` USDC transfer; that branch
is `enter_contest_with_usdc`, gated behind a flag, and with the flag off the path
raises "No entry tokens" instead.

| Branch | Where — each row names its owner; `ContestsController#enter` is `app/controllers/contests_controller.rb:745-920` |
|---|---|
| contest cancelled → 422 | `#enter` at `:749-752` |
| self-custodied → 422 + `self_custodied` | `#enter` at `:774-780` |
| cart entry; survivor auto-creates | `#enter` at `:782-786` |
| `onchain_session?` → 422 "use prepare_entry" | `#enter` at `:816-822` |
| self-custody account in a web2 session → `web3_step_up_required` | `#enter` at `:867-874` |
| hand-off to `Entries::ManagedEntry#call`, inside `rescue_and_log` | `#enter` at `:891` |
| `@contest.with_lock` — `Entries::ManagedEntry#call` is `app/services/entries/managed_entry.rb:67-118` | `#call` at `:77` |
| `assert_enterable!` pre-flight — `Entry#assert_enterable!` | `Entries::ManagedEntry#call` at `:82`; definition `app/models/entry.rb:125-159` |
| season configured? | `Entries::ManagedEntry#call` at `app/services/entries/managed_entry.rb:87-92` |
| paid contest with no on-chain PDA → refuse | `#call` at `:98-100` |
| payment branch — `Entries::ManagedEntry#fund!` | `:150-229` |
| token → `Solana::Vault#enter_contest_with_token` | `#fund!` at `:169-184` |
| no token, USDC allowed → `Solana::Vault#enter_contest_with_usdc` | `#fund!` at `:185-222` |
| neither → "No entry tokens" | `#fund!` at `:224` |
| durable capture, OUTSIDE the lock | `#call` at `:112` |
| `Entries::ManagedEntry#finalize!` → `Entry#confirm!` | `:240-266` |
| transient failure after the spend → `Entries::OnchainReconcileJob.perform_later` | `#finalize!` at `:265` |

**Why the gate ordering is sacred:** incident 2026-06-08 — the consume ran
before a validation gate; the gate then failed and the user was paid-on-chain
but `cart` in the app. A reconciler cannot heal a *genuine* validation failure
(re-running hits the same gate), so all reversible gates run BEFORE the spend,
and only *transient* post-spend failures are left for the reconciler.

## 2a. Agent API — `POST /api/v1/contests/:slug/entries` (same path, no cart, one spend per key)

The contract an agent sees is in [`docs/AGENT_API.md`](../AGENT_API.md). This is
what it does to the tree above. The MCP tool `submit_entry` (`POST /mcp`) enters
this tree at the same point, through the same operation, with the idempotency
key as an argument instead of a header.

```
create (Api::V1::EntriesController)
├─ frozen account → 403 · age gate on, unverified → 403        (before anything)
├─ no / malformed Idempotency-Key, matchup_ids, allow_usdc → 400 (nothing recorded)
└─ Entries::ApiSubmission#call
    ├─ acquire, under the PLAYER row lock: one ApiEntryRequest per (player, key)
    │    same key, different body        → 409 idempotency_key_reused
    │    succeeded                       → replay the stored 201, run nothing
    │    a request of this player's for this contest is in flight → 409
    ├─ a doubt left by an earlier attempt is settled FIRST (never spend past it)
    │    entry row on file               → finish confirming it (reconciler)
    │    paid ticket on chain, no row    → build the entry on it (adopt)
    │    transaction could still land    → 503, spend nothing
    ├─ gates that need no entry row: survivor, cancelled, coming soon, not open,
    │    locked, picks not six pickable ids, wallet the server cannot sign for
    ├─ token read, authoritative: no token and no allow_usdc → no_entry_token
    │    (an unreadable chain is 503, never "no token")
    └─ Entries::ManagedEntry#call { build the entry INSIDE the contest lock }
         first, inside the lock, what its previous holder may have left:
           this attempt no longer owns the key  → stop, 409, spend nothing
           the key's entry was committed        → finish that one instead
           a spend is still in doubt            → 503
           a paid ticket with no entry row      → build the entry on it
         then §2 from contest.with_lock down, with the ownership check
         repeated immediately before the chain call. The row exists only if
         the spend commits; the player's web cart is never read or written.
─ confirmed → 201 {entry, funding}, stored for replay
─ paid, confirm failed → 202 pending; the same key (or the reconcile job) finishes it
─ chain call failed → `failed` ONLY for a failure that proves nothing landed
  (the program refusing the instruction); anything else, "simulation failed:
  already been processed" included, → 503 and the key is `uncertain`
```

| Branch | Where — `Entries::ApiSubmission` is `app/services/entries/api_submission.rb` |
|---|---|
| the operation both surfaces run (the REST action and the MCP tool `submit_entry`) — `Api::V1::Operations::SubmitEntry#call` | `app/services/api/v1/operations/submit_entry.rb:24-38` |
| one record per (player, key), one live request per player and contest — `Entries::ApiSubmission#acquire` | `app/services/entries/api_submission.rb:211-235` |
| settle an earlier doubt before spending — `Entries::ApiSubmission#run` | `:250-281` |
| the fence: this attempt still owns the key, checked inside the contest lock — `Entries::ApiSubmission#fence!` | `:297-303` |
| the gates that need no row — `Entries::ApiSubmission#assert_submittable!` | `:355-371` |
| token only by default, on a read that cannot lie — `Entries::ApiSubmission#assert_token_or_usdc!` | `:388-400` |
| the entry built inside the contest lock — `Entries::ApiSubmission#build_entry` | `:329-347` |
| a paid ticket no entry row holds — `Entries::ApiSubmission#find_orphan` | `:619-649` |
| what a failure means for the key — `Entries::ApiSubmission#settle_failure` | `:507-542` |
| the allow-list of failures that prove nothing landed — `Entries::ApiSubmission#proven_unlanded?` | `:546-551` |
| the states and the two clocks — `ApiEntryRequest#uncertain_since` | `app/models/api_entry_request.rb:97-102` |

**The web cart and the API coexist by never sharing a row.** The browser's
cart is the `cart` entry `ContestsController#toggle_selection` builds; `#enter`
submits that row. The API creates its own row inside the contest lock's
transaction, so it is visible to nobody until the spend has committed, and then
only for the instant before `Entry#confirm!` makes it `active`. The one time it
lingers as `cart` is the strand of §4 case 4 (paid, confirm failed): the same
shape, carrying its signature, healed by the same reconciler.

## 3. Web3 / Phantom path — Phantom-FIRST, three requests

### 3a. `POST prepare_entry` (nothing moves here)

```
prepare_entry
├─ cancelled / geo-blocked / frozen account / not an onchain_session → 422
├─ picks == 6, no started games, contest not full → 422 with reason
├─ assign_onchain_entry_number!   (probes chain for a free slot — survives
│                                  orphaned PDAs from a contest Reset)
├─ ensure_user_account            ← on-chain username validation lives here:
│     6020 UsernameReserved / 6021 InvalidChars / 6022 TooShort → friendly
│     "change your username at /account" message (house accounts use the
│     v0.25 admin path instead)
├─ ensure ATA for the SELECTED currency (usdc default | usdt if accepts_usdt,
│     else 422 — and 6027 EntryFeeNotSet maps friendly if it slips through)
├─ build UNSIGNED tx — FRESH BLOCKHASH, never the durable nonce (see §6),
│     admin reserved as fee-payer but unsigned
└─ PendingTransaction created: status=pending, NO signature
    → returns serialized_tx + ptx_slug to the client
```

| Branch | Where — each row names its owner; `ContestsController#prepare_entry` is `app/controllers/contests_controller.rb:983-1145` |
|---|---|
| not an `onchain_session?` → 403 | `#prepare_entry` at `:1006` |
| full / wrong pick count / started game | `#prepare_entry` at `:1030-1037` |
| `Entry#assign_onchain_entry_number!` | `#prepare_entry` at `:1046`; definition `app/models/entry.rb:307-322` |
| `Solana::Vault#ensure_user_account` | `#prepare_entry` at `app/controllers/contests_controller.rb:1051` |
| username codes 6020-6022 → friendly message, in `Solana::ErrorInterpreter.interpret` | `app/services/solana/error_interpreter.rb:184-196` |
| ATA for the SELECTED currency — `Solana::Vault#ensure_ata` | `#prepare_entry` at `app/controllers/contests_controller.rb:1081` |
| unsigned tx on a FRESH blockhash — `Solana::Vault#build_enter_contest` sets no durable nonce | `app/services/solana/vault.rb:2172-2260` |
| `PendingTransaction` created, no signature | `#prepare_entry` at `app/controllers/contests_controller.rb:1102-1122` |

### 3b. Phantom signs (client)

- User can dismiss or Phantom can invalidate the request → the client POSTs
  `discard_prepared_entry`. `ContestsController#discard_prepared_entry`
  (`app/controllers/contests_controller.rb:1153-1187`) checks ownership
  (`:1160-1166`) and expires only this user's signatureless PT (`:1179-1181`).
  The error card offers **Try Again**; that user click refreshes the session
  snapshot and returns to §3a for new wire bytes and a fresh blockhash without
  reloading the page. Signed PTs cannot be discarded through this endpoint.
- **Phantom may inject Lighthouse guard instructions at arbitrary positions**
  (mainnet only). Its assertion instructions are admitted by design; its
  memory instructions are refused, because one of them can spend the fee
  payer's SOL — see §6.

### 3c. `POST confirm_onchain_entry` (the money request)

```
confirm_onchain_entry
├─ cancelled / entry not found / wallet not linked / signed_tx missing → 4xx
├─ assert_enterable!  PRE-FLIGHT     ← re-run BEFORE the irreversible part:
│     a lock-time/full/duplicate that changed since prepare fails HERE,
│     before anything is signed or broadcast
├─ builds the expectation: Solana::Vault#cosign_expectation rebuilds it from
│     the wire the server stored for this entry, never from the request
├─ C1 cosign guard: Solana::Cosign::Expectation#verify!  (server NEVER blind-cosigns)
│     allowlist per instruction: exactly ONE enter_contest bound to THIS
│     entry's server-derived PDA · signer set exactly admin + this wallet ·
│     ComputeBudget (limit + price only, admin's priority fee capped at 10x
│     our builder's) · Lighthouse ASSERTIONS only (admit_lighthouse!: variants
│     2-17 can only fail the tx; MemoryWrite 0 could make the fee payer fund a
│     memory account, so it, MemoryClose 1, empty data and unknown variants
│     are refused).
│     NO other instruction, System included: an extra or altered instruction
│     fails the exact-match comparison rather than a named case.
│     ANYTHING else → 422 code=tx_rejected, nothing signed, nothing broadcast
├─ cosign (admin signature filled into the Phantom-signed bytes)
├─ simulateTransaction pre-flight (sig_verify:false, replaceRecentBlockhash:true)
│     program errors surface here with logs → 422, nothing broadcast
├─ PT stamped with tx_signature IMMEDIATELY, status=submitted — before_send:,
│     run BEFORE the broadcast (A1 — closes the gap where a crash between
│     broadcast and stamp left an unrecorded, unrepeatable-to-detect payment)
├─ ★ BROADCAST (send_and_confirm) — money moves on success
├─ verify_and_confirm_onchain_entry!  (server-derived PDA cross-check,
│     OPSEC-010: the broadcast tx must be OUR enter_contest signed by the
│     user's wallet writing to the derived PDA) → entry active
└─ PT confirmed, chat announce, seeds fanout, success modal
```

| Branch | Where — each row names its owner; `ContestsController#confirm_onchain_entry` is `app/controllers/contests_controller.rb:1330-1469` |
|---|---|
| `assert_enterable!` PRE-FLIGHT | `#confirm_onchain_entry` at `:1354` |
| build the expectation — `Solana::Vault#cosign_expectation` | `#confirm_onchain_entry` at `:1383-1387`; definition `app/services/solana/vault.rb:3405-3448` |
| C1 cosign guard — `Solana::Cosign::Expectation#verify!` | invoked inside `#cosign_and_broadcast_entry` below; definition `solana-studio lib/solana/cosign/expectation.rb` |
| cosign + simulate + broadcast — `Solana::Vault#cosign_and_broadcast_entry` | `#confirm_onchain_entry` at `app/controllers/contests_controller.rb:1405-1409`; definition `app/services/solana/vault.rb:3529-3532` |
| PT stamped with `tx_signature` immediately, BEFORE broadcast (`before_send:`) | `#confirm_onchain_entry` at `app/controllers/contests_controller.rb:1408` |
| `ContestsController#verify_and_confirm_onchain_entry!` | `#confirm_onchain_entry` at `:1415-1418`; definition `:2553-2569` |
| PT confirmed | `#confirm_onchain_entry` at `:1420` |

## 4. Can funds be taken without an entry? (the full inventory)

| # | Scenario | Funds state | Breadcrumb | Recovery |
|---|----------|-------------|------------|----------|
| 1 | Web3: any failure BEFORE broadcast (guard, simulation, Phantom dismissal) | **Nothing moved** | signatureless pending PT | A signing failure gets an in-place **Try Again** action that expires the unsigned PT and prepares fresh wire bytes. Other stale PTs auto-expire on page load. |
| 2 | Web3: broadcast OK, verification/DB error after | USDC/USDT **paid**, entry on-chain, app shows `cart` | PT `submitted` + tx_signature | Auto: next contest-page visit triggers the recovery modal → §5.1 promotes to `active` without re-charging |
| 3 | Web3: the process dies between the stamp and the broadcast attempt | Nothing moved, or the PT already names a signature that was never handed to any node | PT `submitted` + `tx_signature`, or none | **Closed** (turf-adopts-cosign-primitives): `before_send:` stamps the signature before the broadcast is attempted, not after one succeeds, so a crash here can no longer strand a paid entry with zero app breadcrumb — the row is either untouched (case 1) or already carries the exact signature to reconcile |
| 4 | Web2 token: consume OK, `confirm!` transient failure | Token **consumed**, entry on-chain, app `cart` | entry row carries `onchain_tx_signature` (durable capture) | Auto: `Entries::OnchainReconcileJob` enqueued inline; also healed by the no-arg sweep |
| 5 | Web2 USDC: transfer OK, `confirm!` transient failure | USDC **paid** | same durable capture | Same reconciler |
| 6 | Web3 paid (case 2) but the user never returns to the contest page | Paid, entry on-chain, app `cart` | stamped PT sits `submitted` | **Gap**: no scheduled PT sweeper today — `config/schedule.yml` schedules the deposit and CONTEST reconcilers but not `Entries::OnchainReconcileJob`, so heal requires the user's visit or an operator running the reconcile rake. Recommended follow-up: schedule `Entries::OnchainReconcileJob` (no-arg sweep) + extend the sweep to poll stamped PTs |
| 8 | Agent API: the chain call's outcome is unknown (confirmation timeout, dropped connection), or the process died mid-request | Token/USDC **may be** spent; no entry row (the lock transaction rolled back) | the `ApiEntryRequest` row, `uncertain` (or `executing` and stale) | The next request for that player and contest, same key or new: adopts the paid ticket if one is on chain, answers 503 while the transaction could still land, and only then lets a spend through (§2a). The window is wall-clock (150s), not the transaction's own `lastValidBlockHeight`. **Gap**: a process killed in the middle of its chain call, after outliving both clocks, while a retry of the same key already waits on the contest lock, is not seen by that retry. **Gap**: nothing sweeps these rows, so an agent that never comes back leaves a paid ticket unclaimed until an operator looks |
| 7 | Contest cancelled after entries | Prize pool refunded to creator on-chain; **entry fees stay operator revenue** | — | Operator playbook: `mint_entry_token` goodwill credits to affected entrants |

A failed/rejected on-chain transaction **never** moves funds — Solana txs are
atomic. The only "stuck" class is *succeeded-on-chain but app didn't finish*,
and every such case except #6 self-heals automatically.

## 5. Recovery channels — what triggers them, what they heal

### 5.1 Client recovery modal → `POST recover_pending_entry` (web3)
- **Trigger**: automatic, on contest-page load, ONLY when the viewer has a
  pending/submitted PT **with a tx_signature** (= broadcast actually happened;
  money may have moved) — `ContestsController#find_pending_recovery_ptx`
  (`app/controllers/contests_controller.rb:2714-2734`) returns only a signed one
  (`:2733`). Signatureless PTs trigger nothing — stale ones
  (>10 min, never racing a mid-confirm tab) are silently expired.
- **Logic**, in `ContestsController#recover_pending_entry`
  (`app/controllers/contests_controller.rb:1219-1317`): entry already active →
  confirm PT, done (`:1240`). Signature blank → PT failed, user retries (`:1259-1261`). Signature present → `getSignatureStatuses` poll:
  landed clean → full verify → promote to `active` (no re-charge); on-chain
  err → PT failed, retry is safe (`:1274-1276`); still propagating →
  "processing", client keeps polling (`:1270-1272`, ~30s budget). A landed
  signature runs the full `verify_and_confirm_onchain_entry!` (`:1292-1294`).
- **Safety**: `ContestsController#recover_pending_entry` double-checks ownership —
  initiator address (`app/controllers/contests_controller.rb:1223`) AND
  `entry.user_id` (`:1232`), Lazarus #1; a retry never collides because `assign_onchain_entry_number!`
  probes the chain for a free slot.

### 5.2 `Entries::OnchainReconcileJob` / `OnchainReconciler` (web2)
- **Triggers**: (a) enqueued inline by `Entries::ManagedEntry#finalize!`
  when `confirm!` fails after a successful consume/transfer
  (`app/services/entries/managed_entry.rb:265`), for the browser and the agent API alike; (b) a no-arg sweep over all
  eligible open contests via the `reconcile_onchain` task
  (`lib/tasks/entries.rake:33`) or `Entries::OnchainReconcileJob#perform` with no id
  (`app/jobs/entries/onchain_reconcile_job.rb:13-42`, sweep branch at `:26`), which
  calls `Entries::OnchainReconciler.run` (`app/services/entries/onchain_reconciler.rb:84-98`).
  Idempotent — never double-enters or double-charges.
- **Heals**: `cart` entries (signature on the row → fast path; none → chain
  probe), plus `abandoned` rows that can prove a broadcast → converge to
  `active`, announce in chat on heal.
- **What proves a broadcast for an `abandoned` row** — one rule, two records,
  because there are two entry paths, both read by
  `Entries::OnchainReconciler.reconcilable?`
  (`app/services/entries/onchain_reconciler.rb:201-206`) and its
  `broadcast_proof?` (`:214-218`): the consume signature **on the ENTRY**
  (§2, the managed durable capture → fast path, slot spared) **or** a signed
  `PendingTransaction` targeting it (§3c, the Phantom path → chain probe, slot
  released). The managed half was added by `reach-managed-abandoned-strand`;
  before it, the shape carrying the strongest proof available was the one
  refused, and its owner could be issued a fresh slot and pay twice. Note this
  is the SIGNATURE, never `onchain_entry_id` — a comped
  `EnterContestWithToken` stamps a PDA and moves no USDC.

### 5.3 Page-load stale-PT expiry (web3 hygiene)
Signatureless pending PTs older than 10 minutes are flipped to `expired`
during contest-page load, inside `ContestsController#find_pending_recovery_ptx`
(`app/controllers/contests_controller.rb:2729-2731`). Pure cleanup; never touches
a PT with a signature.

### 5.4 Operator surfaces (manual)
`/admin/transactions` (on-chain audit), `/admin/outbound_requests` (every RPC
with status + body), `/error_logs` (every `rescue_and_log` capture with entry
target context), Sentry, LogRocket session replay (the `[contest-entry]`
console breadcrumbs + `[cosign][rejected]` server logs share identifiers).

## 6. Mainnet-only behaviors (the 2026-06-11 lessons)

The prod entry path has behaviors **devnet can never exercise**. Any change to
signed-wire validation, simulation, or broadcast must be reasoned against all
three:

1. **Phantom injects Lighthouse guard instructions at signing time, mainnet
   only.** The cosign expectation must admit the Lighthouse program, or every
   protected Phantom signer is rejected — `Solana::Cosign::LIGHTHOUSE_PROGRAM_ID`
   is one of `Solana::Cosign::DEFAULT_EXTRA_PROGRAMS`, and each of its
   instructions is handed to `Expectation#admit_lighthouse!` (solana-studio
   `lib/solana/cosign/expectation.rb`). PR #134 admitted the program.
   Accepting the program does NOT mean accepting every Lighthouse instruction.
   Its first data byte is a variant, and two variants move the payer's
   lamports: `MemoryWrite` (0) makes the signer it names as payer fund a
   memory account whose size the instruction chooses, and `MemoryClose` (1)
   refunds one. The house fee payer signs every cosigned wire, so an unguarded
   `MemoryWrite` could lock house SOL and starve every gasless entry. Only
   variants 2-17 (`Solana::Cosign::LIGHTHOUSE_ASSERTIONS`) are pure post-state
   assertions, which can fail the tx but never move funds. So
   `admit_lighthouse!` admits variants 2-17 and refuses `MemoryWrite`,
   `MemoryClose`, empty data and any unknown variant; the entry, create-contest
   and cash-out cosigns all judge their wires against the same `Expectation`.
   The test is the variant byte, not "does it name the fee payer": the real
   Phantom mainnet wires the house has cosigned carry `AssertAccountInfoMulti`
   (6) and `AssertTokenAccountMulti` (10), and each has a variant-6 assertion
   on the fee payer's own post-state, so refusing on the fee payer would
   reject them all and repeat the 2026-06-11 outage. PR #755 added the guard.
2. **Simulation of any tx whose blockhash isn't in the recent queue needs
   `replaceRecentBlockhash: true`** (sigVerify must be false alongside it) —
   `Solana::Vault#cosign_and_broadcast_entry` simulates with both, through
   `Solana::Cosign::Completer#run_simulation!` (solana-studio
   `lib/solana/cosign/completer.rb`). PR #135.
3. **Never anchor user-driven Phantom-signed txs on a shared durable nonce.**
   Phantom's injection position can displace the advance from instruction 0
   (un-recognizing the nonce → BlockhashNotFound at preflight), and one nonce
   account anchors ONE in-flight tx — guaranteed contention under concurrent
   entrants. Entries use a fresh blockhash (re-prepared seconds before
   signing); the durable nonce is for slow operator cosigns only.
   `Solana::Vault#build_enter_contest` pins `dn = nil` with that reasoning
   (`app/services/solana/vault.rb:2217-2253`). PR #136.

<!-- citation-guard: enforced -->
