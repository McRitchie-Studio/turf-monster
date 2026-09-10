# Submit Entry — decision tree, failure points, and recovery channels

> **Code is law.** Every claim below cites `path/to/file.rb:NN` from the current
> codebase, and a bare `:NN` inherits the nearest preceding path — file context
> resets at each `##` heading. The number is bookkeeping; the SYMBOL beside it is
> the claim, and `test/docs/workflow_citation_docs_test.rb` reddens when a citation
> stops landing inside the definition its prose names. The ASCII trees stay
> uncited so they remain readable; the table under each one carries the citations
> for its branches.
> That symbol check reaches **66 of the 70 citations** here. The other **4** sit in
> code with no enclosing definition the guard can derive: one
> `lib/tasks/entries.rake` task body and one class-body constant in
> `app/services/solana/vault.rb`, plus **All 2 citations on
> `app/javascript/solana_utils.js`** — a `.js` file, where the guard reads no
> definitions at all because it parses only `.rb` and inline JS in `.erb`. Those ride
> the weaker LITERAL fallback: it proves the words the prose quotes are present in
> the cited lines, not that the code is. The symbol branch here is also WIDE in
> places: every row of the §2 and §3 tables lands inside one long action
> (`#enter` is 223 lines, `#prepare_entry` 148, `#confirm_onchain_entry` 119), so a
> green row proves the number is inside the right action, not that it is on the
> right line — each was read against the code by hand on 2026-09-09.
>
> **Cited since 2026-09-09.** Until then this document named its symbols and pointed
> at none of them, which made it invisible to the guard rather than weakly checked.
> The same pass corrected two branches of the §2 tree that the code had stopped
> taking — see the note under it.

Written 2026-06-11, the day the full web3 path was proven on mainnet (three
prod-only blockers fixed the same morning — see "Mainnet-only behaviors" at the
bottom). Source of truth: `ContestsController#enter`, `#prepare_entry`,
`#confirm_onchain_entry`, `#recover_pending_entry`, `Solana::Vault`
(`assert_entry_cosign_safe!`, `cosign_and_broadcast_entry`),
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
| guest → auth modal — `confirmEntry()` | `app/views/contests/_turf_totals_board.html.erb:1574-1579` |
| client preflight — the `eligibilityBlocker` export | `app/javascript/solana_utils.js:870`, mirrored onto `window` at `:958` |
| the blocker, re-checked inside `confirmEntry()` at submit time | `app/views/contests/_turf_totals_board.html.erb:1584-1588` |
| route by session — `useOnchainFlow = sess.isWeb3 && this.contestOnchain` in `confirmEntry()` | `:1630`, branch taken at `:1644` |

Currency pick (web3): USDC-first, USDT only when the contest's `accepts_usdt`
is true (contests created before 2026-06-11 are USDC-only forever — their
on-chain `entry_fee_by_currency[1]` is zero and immutable).
`ContestsController#prepare_entry` enforces it server-side
(`app/controllers/contests_controller.rb:983-993`).

## 2. Web2 / managed path — `POST enter` (server signs, synchronous)

```
enter
├─ contest cancelled?            → 422 (terminal)
├─ user self-custodied?          → 422 + self_custodied flag (client routes to Phantom; server MUST NOT auto-sign)
├─ cart entry exists?            → no → error (survivor contests auto-create)
├─ onchain_session?              → 422 "use prepare_entry" (a wallet session
│                                   never enters here — it signs its own tx)
├─ self-custody account, web2 session? → 422 + web3_step_up_required blocker
└─ contest.with_lock              (serialized per contest)
    ├─ assert_enterable!          ← ALL read-only gates BEFORE any spend:
    │     picks == 6, no started games, lock time, contest full,
    │     per-user entry limit, duplicate combo
    ├─ season configured?         → raise (clear msg, not a cryptic Anchor error)
    ├─ paid contest but no on-chain PDA? → refuse (no payment rail = no entry)
    └─ PAYMENT BRANCH
        ├─ managed wallet + has unconsumed token
        │    → enter_contest_with_token   ★ IRREVERSIBLE: atomic consume + entry + seeds
        │      (no USDC moves — the token IS the payment; cache busted after)
        ├─ managed wallet, no token, AppFlags.web2_usdc_entry? on
        │    → balance pre-check, then enter_contest_with_usdc (server signs
        │      with the encrypted keypair)   ★ IRREVERSIBLE: USDC transfer
        │      (USDT in the web2 path is a phase-2 task — web3 only today)
        └─ neither → raise "No entry tokens. Buy at /tokens/buy"
─ durable capture (OUTSIDE the lock): entry.update!(onchain_tx_signature,
  onchain_entry_id) — the paid-proof survives anything that fails after this
─ finalize_managed_entry! → Entry#confirm! (re-runs the same gates as backstop)
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

| Branch | Where, in `ContestsController#enter` (`app/controllers/contests_controller.rb:667-889`) unless named |
|---|---|
| contest cancelled → 422 | `:671-674` |
| self-custodied → 422 + `self_custodied` | `:696-702` |
| cart entry; survivor auto-creates | `:704-707` |
| `onchain_session?` → 422 "use prepare_entry" | `:738-744` |
| self-custody account in a web2 session → `web3_step_up_required` | `:789-795` |
| `@contest.with_lock` | `:821` |
| `assert_enterable!` pre-flight — `Entry#assert_enterable!` | `:824`; definition `app/models/entry.rb:125-159` |
| season configured? | `app/controllers/contests_controller.rb:829-831` |
| paid contest with no on-chain PDA → refuse | `:838-840` |
| payment branch — `ContestsController#resolve_web2_entry_funding!` | `:1821-1893` |
| token → `Solana::Vault#enter_contest_with_token` | `:1837-1849` |
| no token, `AppFlags.web2_usdc_entry?` → `Solana::Vault#enter_contest_with_usdc` | `:1850-1889` |
| neither → "No entry tokens" | `:1891` |
| durable capture, OUTSIDE the lock | `:858` |
| `ContestsController#finalize_managed_entry!` → `Entry#confirm!` | `:1992-2018` |
| transient failure after the spend → `Entries::OnchainReconcileJob.perform_later` | `:2017` |

**Why the gate ordering is sacred:** incident 2026-06-08 — the consume ran
before a validation gate; the gate then failed and the user was paid-on-chain
but `cart` in the app. A reconciler cannot heal a *genuine* validation failure
(re-running hits the same gate), so all reversible gates run BEFORE the spend,
and only *transient* post-spend failures are left for the reconciler.

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

| Branch | Where, in `ContestsController#prepare_entry` (`app/controllers/contests_controller.rb:952-1099`) unless named |
|---|---|
| not an `onchain_session?` → 403 | `:975` |
| full / wrong pick count / started game | `:1000-1005` |
| `Entry#assign_onchain_entry_number!` | `:1015`; definition `app/models/entry.rb:307-322` |
| `Solana::Vault#ensure_user_account` | `app/controllers/contests_controller.rb:1020` |
| username codes 6020-6022 → friendly message, in `Solana::ErrorInterpreter.interpret` | `app/services/solana/error_interpreter.rb:184-196` |
| ATA for the SELECTED currency — `Solana::Vault#ensure_ata` | `app/controllers/contests_controller.rb:1050` |
| unsigned tx on a FRESH blockhash — `Solana::Vault#build_enter_contest` sets no durable nonce | `app/services/solana/vault.rb:1331-1345` |
| `PendingTransaction` created, no signature | `app/controllers/contests_controller.rb:1071-1083` |

### 3b. Phantom signs (client)

- User can dismiss or Phantom can invalidate the request → the client POSTs
  `discard_prepared_entry`. `ContestsController#discard_prepared_entry`
  (`app/controllers/contests_controller.rb:1107-1141`) checks ownership
  (`:1114-1120`) and expires only this user's signatureless PT (`:1133-1135`).
  The error card offers **Try Again**; that user click refreshes the session
  snapshot and returns to §3a for new wire bytes and a fresh blockhash without
  reloading the page. Signed PTs cannot be discarded through this endpoint.
- **Phantom may inject Lighthouse guard instructions at arbitrary positions**
  (mainnet only). Allowed by design — see §6.

### 3c. `POST confirm_onchain_entry` (the money request)

```
confirm_onchain_entry
├─ cancelled / entry not found / wallet not linked / signed_tx missing → 4xx
├─ assert_enterable!  PRE-FLIGHT     ← re-run BEFORE the irreversible part:
│     a lock-time/full/duplicate that changed since prepare fails HERE,
│     before anything is signed or broadcast
├─ C1 cosign guard: assert_entry_cosign_safe!  (server NEVER blind-cosigns)
│     allowlist per instruction: exactly ONE enter_contest bound to THIS
│     entry's server-derived PDA · advanceNonceAccount only if configured ·
│     ComputeBudget · Lighthouse (pure assertions — can only fail the tx).
│     ANYTHING else → 422 code=tx_rejected, nothing signed, nothing broadcast
├─ cosign_wire (admin signature filled into the Phantom-signed bytes)
├─ simulateTransaction pre-flight (sig_verify:false, replaceRecentBlockhash:true)
│     program errors surface here with logs → 422, nothing broadcast
├─ ★ BROADCAST (send_and_confirm) — money moves on success
├─ PT stamped with tx_signature IMMEDIATELY, status=submitted   (A1 — BEFORE
│     verification, so no later failure can erase the paid-proof)
├─ verify_and_confirm_onchain_entry!  (server-derived PDA cross-check,
│     OPSEC-010: the broadcast tx must be OUR enter_contest signed by the
│     user's wallet writing to the derived PDA) → entry active
└─ PT confirmed, chat announce, seeds fanout, success modal
```

| Branch | Where, in `ContestsController#confirm_onchain_entry` (`app/controllers/contests_controller.rb:1284-1402`) unless named |
|---|---|
| `assert_enterable!` PRE-FLIGHT | `:1308` |
| C1 cosign guard — `Solana::Vault#assert_entry_cosign_safe!` | `:1331`; definition `app/services/solana/vault.rb:2196-2303` |
| cosign + simulate + broadcast — `Solana::Vault#cosign_and_broadcast_entry` | `app/controllers/contests_controller.rb:1340`; definition `app/services/solana/vault.rb:2400-2420` |
| PT stamped with `tx_signature` immediately | `app/controllers/contests_controller.rb:1352` |
| `ContestsController#verify_and_confirm_onchain_entry!` | `:1358-1361`; definition `:2554-2570` |
| PT confirmed | `:1363` |

## 4. Can funds be taken without an entry? (the full inventory)

| # | Scenario | Funds state | Breadcrumb | Recovery |
|---|----------|-------------|------------|----------|
| 1 | Web3: any failure BEFORE broadcast (guard, simulation, Phantom dismissal) | **Nothing moved** | signatureless pending PT | A signing failure gets an in-place **Try Again** action that expires the unsigned PT and prepares fresh wire bytes. Other stale PTs auto-expire on page load. |
| 2 | Web3: broadcast OK, verification/DB error after | USDC/USDT **paid**, entry on-chain, app shows `cart` | PT `submitted` + tx_signature | Auto: next contest-page visit triggers the recovery modal → §5.1 promotes to `active` without re-charging |
| 3 | Web3: broadcast OK, even the PT stamp failed (DB death in the ~ms between broadcast and the stamp) | Paid on-chain, **no app breadcrumb** | on-chain Entry PDA only | Manual (operator): explorer + `/admin/transactions` + OutboundRequest audit. Window is deliberately tiny; residual risk accepted |
| 4 | Web2 token: consume OK, `confirm!` transient failure | Token **consumed**, entry on-chain, app `cart` | entry row carries `onchain_tx_signature` (durable capture) | Auto: `Entries::OnchainReconcileJob` enqueued inline; also healed by the no-arg sweep |
| 5 | Web2 USDC: transfer OK, `confirm!` transient failure | USDC **paid** | same durable capture | Same reconciler |
| 6 | Web3 paid (case 2) but the user never returns to the contest page | Paid, entry on-chain, app `cart` | stamped PT sits `submitted` | **Gap**: no scheduled PT sweeper today — `config/schedule.yml` schedules the deposit and CONTEST reconcilers but not `Entries::OnchainReconcileJob`, so heal requires the user's visit or an operator running the reconcile rake. Recommended follow-up: schedule `Entries::OnchainReconcileJob` (no-arg sweep) + extend the sweep to poll stamped PTs |
| 7 | Contest cancelled after entries | Prize pool refunded to creator on-chain; **entry fees stay operator revenue** | — | Operator playbook: `mint_entry_token` goodwill credits to affected entrants |

A failed/rejected on-chain transaction **never** moves funds — Solana txs are
atomic. The only "stuck" class is *succeeded-on-chain but app didn't finish*,
and every such case except #3/#6 self-heals automatically.

## 5. Recovery channels — what triggers them, what they heal

### 5.1 Client recovery modal → `POST recover_pending_entry` (web3)
- **Trigger**: automatic, on contest-page load, ONLY when the viewer has a
  pending/submitted PT **with a tx_signature** (= broadcast actually happened;
  money may have moved) — `ContestsController#find_pending_recovery_ptx`
  (`app/controllers/contests_controller.rb:2666-2686`) returns only a signed one
  (`:2685`). Signatureless PTs trigger nothing — stale ones
  (>10 min, never racing a mid-confirm tab) are silently expired.
- **Logic**, in `ContestsController#recover_pending_entry`
  (`app/controllers/contests_controller.rb:1173-1271`): entry already active →
  confirm PT, done (`:1193`). Signature blank → PT failed, user retries (`:1213-1215`). Signature present → `getSignatureStatuses` poll:
  landed clean → full verify → promote to `active` (no re-charge); on-chain
  err → PT failed, retry is safe (`:1228-1230`); still propagating →
  "processing", client keeps polling (`:1233-1234`, ~30s budget). A landed
  signature runs the full `verify_and_confirm_onchain_entry!` (`:1246`).
- **Safety**: `ContestsController#recover_pending_entry` double-checks ownership —
  initiator address (`app/controllers/contests_controller.rb:1177`) AND
  `entry.user_id` (`:1186`), Lazarus #1; a retry never collides because `assign_onchain_entry_number!`
  probes the chain for a free slot.

### 5.2 `Entries::OnchainReconcileJob` / `OnchainReconciler` (web2)
- **Triggers**: (a) enqueued inline by `ContestsController#finalize_managed_entry!`
  when `confirm!` fails after a successful consume/transfer
  (`app/controllers/contests_controller.rb:2017`); (b) a no-arg sweep over all
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
(`app/controllers/contests_controller.rb:2681-2683`). Pure cleanup; never touches
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
   only.** The cosign allowlist must accept the Lighthouse program (pure
   post-state assertions, cannot move funds) — the `LIGHTHOUSE_PROGRAM_ID` constant
   (`app/services/solana/vault.rb:48`), admitted inside
   `Solana::Vault#assert_entry_cosign_safe!`, on its `when lighthouse` arm (`:2287-2291`). PR #134.
2. **Simulation of any tx whose blockhash isn't in the recent queue needs
   `replaceRecentBlockhash: true`** (sigVerify must be false alongside it) —
   `Solana::Vault#cosign_and_broadcast_entry` simulates with both
   (`app/services/solana/vault.rb:2412-2413`). PR #135.
3. **Never anchor user-driven Phantom-signed txs on a shared durable nonce.**
   Phantom's injection position can displace the advance from instruction 0
   (un-recognizing the nonce → BlockhashNotFound at preflight), and one nonce
   account anchors ONE in-flight tx — guaranteed contention under concurrent
   entrants. Entries use a fresh blockhash (re-prepared seconds before
   signing); the durable nonce is for slow operator cosigns only.
   `Solana::Vault#build_enter_contest` pins `dn = nil` with that reasoning
   (`app/services/solana/vault.rb:1331-1345`). PR #136.
