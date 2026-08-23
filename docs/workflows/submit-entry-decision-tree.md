# Submit Entry — decision tree, failure points, and recovery channels

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

Currency pick (web3): USDC-first, USDT only when the contest's `accepts_usdt`
is true (contests created before 2026-06-11 are USDC-only forever — their
on-chain `entry_fee_by_currency[1]` is zero and immutable).

## 2. Web2 / managed path — `POST enter` (server signs, synchronous)

```
enter
├─ contest cancelled?            → 422 (terminal)
├─ user self-custodied?          → 422 + self_custodied flag (client routes to Phantom; server MUST NOT auto-sign)
├─ cart entry exists?            → no → error (survivor contests auto-create)
├─ onchain_session? → verify the wallet signature proof (OPSEC-005)
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
        └─ managed wallet, no token
             → enter_contest currency_idx 0 (USDC; server signs with the
               encrypted keypair)              ★ IRREVERSIBLE: USDC transfer
               (USDT in the web2 path is a phase-2 task — web3 only today)
─ durable capture (OUTSIDE the lock): entry.update!(onchain_tx_signature,
  onchain_entry_id) — the paid-proof survives anything that fails after this
─ finalize_managed_entry! → Entry#confirm! (re-runs the same gates as backstop)
    ├─ success → entry active, chat announce, seeds/token client fanout
    └─ TRANSIENT failure after the spend → entry stays `cart` WITH signature
         → Entries::OnchainReconcileJob.perform_later(entry.id)   (§5.2)
```

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

### 3b. Phantom signs (client)

- User can dismiss or Phantom can invalidate the request → the client POSTs
  `discard_prepared_entry`, which expires only this user's signatureless PT.
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

## 4. Can funds be taken without an entry? (the full inventory)

| # | Scenario | Funds state | Breadcrumb | Recovery |
|---|----------|-------------|------------|----------|
| 1 | Web3: any failure BEFORE broadcast (guard, simulation, Phantom dismissal) | **Nothing moved** | signatureless pending PT | A signing failure gets an in-place **Try Again** action that expires the unsigned PT and prepares fresh wire bytes. Other stale PTs auto-expire on page load. |
| 2 | Web3: broadcast OK, verification/DB error after | USDC/USDT **paid**, entry on-chain, app shows `cart` | PT `submitted` + tx_signature | Auto: next contest-page visit triggers the recovery modal → §5.1 promotes to `active` without re-charging |
| 3 | Web3: broadcast OK, even the PT stamp failed (DB death in the ~ms between broadcast and the stamp) | Paid on-chain, **no app breadcrumb** | on-chain Entry PDA only | Manual (operator): explorer + `/admin/transactions` + OutboundRequest audit. Window is deliberately tiny; residual risk accepted |
| 4 | Web2 token: consume OK, `confirm!` transient failure | Token **burned**, entry on-chain, app `cart` | entry row carries `onchain_tx_signature` (durable capture) | Auto: `Entries::OnchainReconcileJob` enqueued inline; also healed by the no-arg sweep |
| 5 | Web2 USDC: transfer OK, `confirm!` transient failure | USDC **paid** | same durable capture | Same reconciler |
| 6 | Web3 paid (case 2) but the user never returns to the contest page | Paid, entry on-chain, app `cart` | stamped PT sits `submitted` | **Gap**: no scheduled PT sweeper today — heal requires the user's visit or an operator running the reconcile rake. Recommended follow-up: schedule `Entries::OnchainReconcileJob` (no-arg sweep) + extend the sweep to poll stamped PTs |
| 7 | Contest cancelled after entries | Prize pool refunded to creator on-chain; **entry fees stay operator revenue** | — | Operator playbook: `mint_entry_token` goodwill credits to affected entrants |

A failed/rejected on-chain transaction **never** moves funds — Solana txs are
atomic. The only "stuck" class is *succeeded-on-chain but app didn't finish*,
and every such case except #3/#6 self-heals automatically.

## 5. Recovery channels — what triggers them, what they heal

### 5.1 Client recovery modal → `POST recover_pending_entry` (web3)
- **Trigger**: automatic, on contest-page load, ONLY when the viewer has a
  pending/submitted PT **with a tx_signature** (= broadcast actually happened;
  money may have moved). Signatureless PTs trigger nothing — stale ones
  (>10 min, never racing a mid-confirm tab) are silently expired.
- **Logic**: entry already active → confirm PT, done. Signature blank →
  PT failed, user retries. Signature present → `getSignatureStatuses` poll:
  landed clean → full verify → promote to `active` (no re-charge); on-chain
  err → PT failed, retry is safe; still propagating → "processing", client
  keeps polling (~30s budget).
- **Safety**: ownership double-checked (initiator address AND entry.user_id —
  Lazarus #1); a retry never collides because `assign_onchain_entry_number!`
  probes the chain for a free slot.

### 5.2 `Entries::OnchainReconcileJob` / `OnchainReconciler` (web2)
- **Triggers**: (a) enqueued inline by `enter` when `confirm!` fails after a
  successful consume/transfer; (b) no-arg sweep over all eligible open
  contests via `rake entries:reconcile_onchain` (operator) or the same job
  with no id. Idempotent — never double-enters or double-charges.
- **Heals**: `cart` entries carrying `onchain_tx_signature` (the durable
  capture) → converge to `active`, announce in chat on heal.

### 5.3 Page-load stale-PT expiry (web3 hygiene)
Signatureless pending PTs older than 10 minutes are flipped to `expired`
during contest-page load. Pure cleanup; never touches a PT with a signature.

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
   post-state assertions, cannot move funds). PR #134.
2. **Simulation of any tx whose blockhash isn't in the recent queue needs
   `replaceRecentBlockhash: true`** (sigVerify must be false alongside it).
   PR #135.
3. **Never anchor user-driven Phantom-signed txs on a shared durable nonce.**
   Phantom's injection position can displace the advance from instruction 0
   (un-recognizing the nonce → BlockhashNotFound at preflight), and one nonce
   account anchors ONE in-flight tx — guaranteed contention under concurrent
   entrants. Entries use a fresh blockhash (re-prepared seconds before
   signing); the durable nonce is for slow operator cosigns only. PR #136.
