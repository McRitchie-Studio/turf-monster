# Session, Auth & Wallet Storage — Audit and Target Architecture

**Task:** https://mcritchie.studio/tasks/audit-session-storage-architecture
**Measured:** 2026-08-25, against `feat/audit-session-storage-architecture` (branched from `accepted` at `e154fc7`).
**Status:** Phase 1 — audit and proposal. **No refactor has been performed.** Every slice in §5 is unstarted and awaits Mr. McRitchie's approval.

Every number and line reference below was re-measured in this worktree. Where the
brief's measured starting state has drifted, the drift is noted inline — the
brief's figures were leads, not findings, and three of them moved.

---

## 0. The idea, in one page

Turf Monster knows three different answers to "does this person have a wallet
right now", and none of them is the true one.

1. **`User#solana_connected?`** — a *database* fact: some wallet address is
   stored on the account. This is what paints the green check.
2. **`SessionContext#mode == :web3`** — a *server session* fact: this session
   proved a wallet signature at some point. This is what the entry gate branches on.
3. **The browser** — whether Phantom is installed, unlocked, and connected to this
   origin *at this instant*. **Nothing in the app stores or exposes this.**

Fact 3 is the only one that decides whether the next signature will succeed, and
it is the one nobody records. That single gap explains defects A, B and C, the
absence of a read-only mode, and why a wallet switch can go unnoticed.

Underneath that sits a storage layer with no owner: 18 browser keys with no
namespace, 13 files writing them, five different writers for one cache key, two
server endpoints answering the same question with different rounding, and a
logout that clears exactly one key and never calls `reset_session`.

The proposal is one new concept — a **WalletSession** that owns the live-signer
answer — plus one **namespaced storage façade** that owns every key, and one
**refresh contract** that everything hydrates through. Eleven slices, ordered so
the first six preserve behaviour exactly and the last five change it deliberately.

---

## 1. The map — every place session, auth, or wallet state lives

### 1.1 Client — Alpine stores (5)

| Store | Registered at | Kind | Owner of |
|---|---|---|---|
| `session` | `app/views/layouts/application.html.erb:473` (inline, `alpine:init`) | State | Canonical viewer identity + funding hints: `loggedIn`, `mode`, `phantomLinked`, `userId`, `address`, `usdcCents`, `usdtCents`, `tokensAvailable`, `web2UsdcEntry`, `ageGateRequired`, `ageVerified`, `walletSetupRequired`, `firstNameRequired`, `walletConnected` |
| `wallet` | `app/javascript/solana_stores.js:41` (module) | State | Live Phantom watcher: `address`, `watching`, `pendingAddress`, `_provider`, `_reauthing` |
| `modals` | `app/views/studio/modals/_host.html.erb:109` (studio-engine partial) | UI | Modal stack |
| `solanaModal` | `app/views/layouts/application.html.erb:612` (inline) | UI façade | Read/write proxy over `modals` for the `onchain-tx` card. Holds no session state. |
| `sidebars` | `app/views/layouts/application.html.erb:370` (inline) | UI | `gearOpen` |

A **second, drifted copy** of `session` and `solanaModal` is registered at
`app/views/layouts/modal_preview.html.erb:63` and `:98` — see §2.2.

**Registration is split three ways** (module / app layout / engine partial), which
is the split the brief flagged. Confirmed, with one correction: the brief listed
`solanaConnectAndVerify`, `postMagicLink` and `fireSuccessConfetti` as inline —
they are, and so are the `session`, `solanaModal` and `sidebars` stores. Only the
`wallet` store loads from a module. The inline block totals **1,058 lines** across
`application.html.erb` (brief said ~1,053 — drift +5).

### 1.2 Client — browser storage keys (18)

All 18 confirmed. **13 files write** (`setItem`/`removeItem`); 20 files reference
storage at all. (The brief's "17 files write" counted readers and comment
mentions.)

| Key | Store | Writer(s) — the owner | Reader(s) | Lifetime rule |
|---|---|---|---|---|
| `inviter_slug` | local | `layouts/application.html.erb:143` | same file `:164` | Cleared on successful `PATCH /account/set_inviter` (`:171`) |
| `lastUserId` | local | `layouts/application.html.erb:952` | same file `:936` | Identity-change sentinel; drives the purge below |
| `pendingAuthStep` | session | `contests/_turf_totals_board.html.erb` (`:400`, `:424` remove) | `:397` | Consumed on read |
| `pendingContestEntry` | local | `contests/_turf_totals_board.html.erb:914` | `:458` | Consumed on read; 30-min freshness guard (`:461`) |
| `phantom_dl_secret` | local | `phantom_deeplink.js:38` | `solana_sessions/phantom_callback.html.erb:167` | `cleanup()` at `:97` |
| `phantom_dl_pubkey` | local | `phantom_deeplink.js:39` | callback | `cleanup()` |
| `phantom_dl_nonce` | local | `phantom_deeplink.js:40` | callback `:239` | `cleanup()` |
| `phantom_dl_nonce_at` | local | `phantom_deeplink.js:41` | callback `:134` | `cleanup()` |
| `phantom_dl_step` | local | `phantom_deeplink.js:42` | callback `:125` | `cleanup()` |
| `phantom_dl_link_mode` | local | `phantom_deeplink.js:43` | callback `:245`, `:255` | `cleanup()` |
| `phantom_dl_cluster` | local | `phantom_deeplink.js:44` | callback | `cleanup()` |
| `phantom_dl_user_id` | local | `phantom_deeplink.js:46` / removed `:48` | callback `:244` | **NOT in `cleanup()`** — see §2.1 |
| `phantom_dl_age_attested` | local | `modals/_wallet_connect.html.erb:100` | callback `:276` | `cleanup()` |
| `seedsNavbar` | local | **five writers** — see §2.3 | 5 readers | Purged on identity change only |
| `seedsLevelUp` | local | `state_fanout.js:124` | `seeds_bar.js:45`, `_seeds_bar.html.erb:60` | Consumed on read |
| `walletSetupAutoConnect` | session | `modals/_wallet_setup.html.erb:267` | same file `:66`, removed `:67` | Consumed on read |
| `walletSetupReopen` | session | `modals/_wallet_setup.html.erb:266` | `layouts/application.html.erb:1147`, removed `:1149` | Consumed on read |
| `seedsNavbar` (quoting) | — | written with `'…'` in `solana_utils.js`/`contests/show.html.erb`, `"…"` in `state_fanout.js`/`seeds_bar.js` | — | Cosmetic, but confirms the brief's read: naming is ad hoc |

**No namespace convention exists** except `phantom_dl_*`. There is no shared
constant file; every key is a string literal at its use site.

### 1.3 Client — cookies

The app writes exactly one non-Rails cookie: `cookies[:reference]` (9 sites,
referral attribution). The Rails session cookie is the only auth-bearing one.

### 1.4 Server — session keys (15)

Written across controllers/services:

`wallet_setup`, `wallet_setup_prompt`, `web3_step_up_prompt`, `onboarding_prompt`,
`onboarding_skipped_first_name`, `true_admin_id`, `impersonated_user_id`,
`impersonation_started_at`, `solana_nonce`, `solana_nonce_at`, `session_token`,
`onchain`, `pending_google_link`, `return_to`, `oauth_popup`.

Owner: `SessionsController` / `SolanaSessionsController` / `ApplicationController`.
The authoritative web3 flag is `session[:onchain]`, read through
`ApplicationController#onchain_session?` (`app/controllers/application_controller.rb:474`).

### 1.5 Server — the user record

`app/models/user.rb`:

| Field / method | Line | Meaning |
|---|---|---|
| `web2_solana_address` | `:64` | Custodial address (managed keypair) |
| `web3_solana_address` | `:65` | Self-custody address (Phantom) |
| `web3_wallet_provider` | `:353` | **The brand that authenticated** — requirement 3 is *already partly implemented* |
| `solana_address` | `:504` | `web3 || web2` — prefers web3 unconditionally (as the brief said) |
| `solana_connected?` | `:303` | `web2.present? \|\| web3.present?` — the DB fact behind defect A |
| `phantom_wallet?` | `:311` | `web3.present?` |
| `managed_wallet?` | `:307` | `web2.present?` |
| `wallet_kind` | `:320` | `:phantom` / `:managed` / `:none` |
| `generate_managed_wallet!` | `:522` | `after_create :89`; **early-returns when `AppFlags.web3_only_onboarding?`**, which defaults **on** (`app/services/app_flags.rb:133`) |

Requirement 2 ("new users are web3") is therefore **already live**: a new account
gets no custodial wallet at all, and links Phantom through the wallet-setup modal.

### 1.6 Server — the canonical context

`SessionContext` is **not in this repo** — it lives in the studio-engine gem at
`/Users/alex/projects/studio-engine/app/models/session_context.rb`. It answers
`mode` from `user` + `onchain_session?` only, and its `#to_h` carries 5 fields.
`ApplicationController#client_session_payload` (`:499`) merges 9 more.

### 1.7 The hydrate endpoints (3)

| Endpoint | Action | Fires on | Writes |
|---|---|---|---|
| `GET /account/session_state` | `accounts_controller.rb:89` | `visibilitychange` >30s away (`layout:863`); BroadcastChannel `tm-session` mismatch (`layout:823`) | `$store.session` + rotates CSRF meta |
| `GET /account/session_refresh` | `accounts_controller.rb:57` | `turbo:load` via `hydrateNavbar` (`layout:127`); `walletRefresh()` button; every on-chain success | `$store.session` cents/tokens, balance pill, ✨ badge, `seedsNavbar`, `data-wallet-tile` spans |
| `GET /admin/usdc_balance` | `admin_controller.rb:403` | `refreshBalance()` (`solana_utils.js:162`) | Same four surfaces, different rules — see §2.4 |

### 1.8 Hydrate triggers for `$store.session` (5 paths, 3 payload shapes)

1. `alpine:init` → `#session-context` JSON (`layout:540`)
2. `turbo:load` → `rehydrateSession()` → `#session-context` (`layout:847`)
3. `pageshow` (bfcache) → `rehydrateSession()` (`layout:854`)
4. `visibilitychange` >30s → `GET /account/session_state` (`layout:863`)
5. BroadcastChannel `tm-session` mismatch → `GET /account/session_state` (`layout:823`)

...plus `refreshSession()` and `refreshBalance()`, which write **cents and tokens
only**, from a different payload shape. Last write wins; there is no version or
timestamp on the store, so a `turbo:load` re-seed from the cache-first
`#session-context` can overwrite fresher RPC values written moments earlier by
`refreshSession()`. It re-converges because `hydrateNavbar` fires `refreshSession()`
on that same `turbo:load` — but the ordering, not a rule, is what saves it.

---

## 2. The redundancy list — with evidence

Each entry names two code paths that answer the same question and shows how they
can disagree.

### 2.1 CONFIRMED — Two enumerations of the `phantom_dl_*` key set, already disagreeing

- **Path 1:** `app/views/solana_sessions/phantom_callback.html.erb:92` —
  `var ALL_KEYS = ['phantom_dl_secret', 'phantom_dl_pubkey', 'phantom_dl_nonce',
  'phantom_dl_nonce_at', 'phantom_dl_step', 'phantom_dl_link_mode',
  'phantom_dl_cluster', 'phantom_dl_age_attested']` — **8 keys**, consumed by
  `cleanup()` at `:97`.
- **Path 2:** `app/views/layouts/application.html.erb:946-949` — a prefix scan,
  `if (k && k.indexOf('phantom_dl_') === 0) localStorage.removeItem(k)` — **all keys**.

`app/javascript/phantom_deeplink.js:46` writes a ninth key, `phantom_dl_user_id`.
It is **absent from `ALL_KEYS`**. So the deeplink callback's `cleanup()` leaves
`phantom_dl_user_id` in localStorage after a completed handshake; only the
layout's identity-change purge removes it, and only on a user change. Two lists
of one set, and they are out of sync today.

### 2.2 CONFIRMED — Two `session` stores, already drifted

`app/views/layouts/modal_preview.html.erb:63` registers a second `session` store
and `:98` a second `solanaModal`. Its own comment at `:88` says:

> *"Same shape as application.html.erb; kept in sync manually. If you touch one, touch the other."*

They are **not** the same shape. The preview copy carries `loggedIn`, `mode`,
`phantomLinked`, `userId`, `address`, `usdcCents`, `usdtCents`, `tokensAvailable`
— and is **missing all six** of `web2UsdcEntry`, `ageGateRequired`, `ageVerified`,
`walletSetupRequired`, `firstNameRequired`, `walletConnected`. Any modal previewed
at `/admin/modals` whose markup reads one of those six gets `undefined` where the
real page gives `false`, so the preview renders a branch the live app never takes.

### 2.3 CONFIRMED — Five writers of `seedsNavbar`, three freshness policies

| # | Writer | Guard |
|---|---|---|
| 1 | `state_fanout.js:117` | Unconditional, from the fanout-computed total |
| 2 | `solana_utils.js:187` (`refreshBalance`) | Only when `data.seeds != null && data.level != null` |
| 3 | `solana_utils.js:293` (`refreshSession`) | **Unconditional** |
| 4 | `components/_seeds_bar.html.erb:101` | **Max-wins** — only when `serverTotal > cacheTotal` |
| 5 | `contests/show.html.erb:34` | Unconditional, from the server render |

**The disagreement:** writer 4 exists specifically to stop a stale server value
from lowering the cache. Writers 3 and 5 have no such guard, and writer 3 can
write a *zero*:

`accounts_controller.rb:63` — `seeds = hydrate[:seeds].to_i`. On an RPC flake
`hydrate[:seeds]` is `nil`, so `session_refresh` returns `seeds: 0` with
`level: User.level_for(0)`. `refreshSession` then writes
`{seeds_total: 0, level: 1, …}` to `seedsNavbar` unconditionally and dispatches
`navbar-seeds-update`. On the **same flake**, `refreshBalance` (writer 2) sees
`seeds: nil` from `/admin/usdc_balance` (`admin_controller.rb:411`, which does not
coerce) and skips the write entirely, preserving the bar.

One RPC flake, two functions, opposite outcomes — one resets the user's seeds bar
to level 1 and caches the zero, the other protects it.

### 2.4 CONFIRMED — Two hydrate endpoints over one data source

Both `AccountsController#session_refresh` and `AdminController#usdc_balance` call
the same `fetch_navbar_hydrate(current_user)` and return overlapping JSON:

| Field | `/admin/usdc_balance` | `/account/session_refresh` |
|---|---|---|
| `balance` (combined) | ✅ server-combined | ❌ client re-combines |
| `usdc` / `usdt` | ✅ | ✅ |
| `sol` | ❌ | ✅ |
| `tokens` | ✅ | ✅ |
| `seeds` | `nil` on flake | `.to_i` → `0` |
| `level` | `nil` on flake | always (→ 1) |
| `seeds_to_next` | ✅ | ❌ |
| `level_up_token_pending` | ❌ | ✅ |

A user-facing hydrate also lives under `/admin/` with `require_admin` explicitly
excepted (`admin_controller.rb:2`) — a routing seam that will surprise the next
reader.

### 2.5 CONFIRMED — The balance-slot rule is implemented twice

`applyBalanceSlotRule()` (`solana_utils.js:376`) documents itself as the single
rule: *"both refreshBalance() and updateNavTokens() call it so the two halves
can't drift."* `refreshSession()` does not call it — it **inlines a partial copy**
at `solana_utils.js:268-281`:

```js
if (isZero && hasTokens) el.classList.add('hidden');
else                     el.classList.remove('hidden');
```

That copy omits both other halves of the rule: the `[data-free-entry-label]`
`is-active` toggle, and the empty-text "loading" case. Today it is *dead weight
rather than a visible bug* — `updateNavTokens(data.tokens)` runs three statements
later (`:281`) and re-applies the real rule over the top. It is a second
implementation of a rule the codebase says has exactly one, kept correct only by
statement ordering inside one function.

There is a **live** divergence in the same pair: `refreshBalance` paints only when
the server-combined `data.balance != null` (i.e. *both* reads landed), while
`refreshSession` paints when *either* `usdc` or `usdt` is non-null and counts the
null side as `0`. On a single-sided RPC flake the two functions paint different
dollar amounts for the same wallet.

### 2.6 CONFIRMED — Two logout key-lists, neither complete, no `reset_session`

- **Client:** the only browser-storage clearing on logout is an inline `onclick`,
  duplicated verbatim in two views —
  `app/views/components/_gear_sidebar.html.erb:84` and
  `app/views/accounts/show.html.erb:195` —
  `try{localStorage.removeItem('pendingContestEntry')}catch(e){}`.
  **One key of eighteen.** The gear-sidebar link carries `data: { turbo: false }`;
  the `/account` link does not, so the two logouts do not even take the same
  navigation path.
- **Server:** `SessionsController#destroy` (`:34`) calls the engine's
  `clear_app_session` (a deny-list of 3 + 7 SSO keys in
  `studio-engine/app/controllers/concerns/studio/error_handling.rb:65`) and then
  re-deletes 5 more by hand (`:73-80`), two of which — `session_token`, `onchain` —
  the engine already deleted. **`reset_session` is never called on logout**
  (`grep` finds it only in `magic_links_controller.rb:115`, on login rotation).

Result: `wallet_setup`, `wallet_setup_prompt`, `web3_step_up_prompt`,
`onboarding_prompt`, `onboarding_skipped_first_name`, `pending_google_link` and
`oauth_popup` **survive logout** in the session cookie. Client-side,
`inviter_slug`, `pendingAuthStep`, `walletSetupAutoConnect` and
`walletSetupReopen` survive too; `seedsNavbar`, `seedsLevelUp` and `phantom_dl_*`
are cleaned up only *later*, by the identity-change sweep on the next page load
(`layout:936`). Requirement 6 is unimplemented, and there is no
`localStorage.clear()` anywhere in `app/` (the one hit is `e2e/audit.spec.js:17`).

### 2.7 CONFIRMED — Three answers to "is there a live signer", none of them live

| Answer | Source | Actually means |
|---|---|---|
| `user.solana_connected?` | `user.rb:303` (DB) | An address is stored on the account |
| `session.mode === 'web3'` | `SessionContext#mode` ← `session[:onchain]` | This session signed *at some point* |
| — | — | **Nothing** records "Phantom is installed, unlocked, and connected right now" |

`eligibilityBlocker()` (`solana_utils.js:548`) branches on `session.mode` and
never asks whether a signer exists. A user who deletes the Phantom extension
keeps `mode: 'web3'`, passes the blocker, and fails at `provider.signTransaction`.
This is the root of requirement 5's absence, and of defects A/B/C.

---

## 3. Known defects — confirmed, with the mechanism

### Defect A — the green check is a database fact (CONFIRMED, and one degree worse)

`app/views/accounts/_solana_wallet_section.html.erb:46`:
`<% if user.solana_connected? %>` gates a green ✓ SVG plus `user.solana_address`.

`solana_connected?` is `web2_solana_address.present? || web3_solana_address.present?`.
So the check is green whenever **any** address is stored — including a purely
custodial one. It says nothing about Phantom, and nothing about *now*.

The extra degree: **the same predicate gates both the page-load hydrate and the
watcher itself.** `layouts/application.html.erb:105` wraps `hydrateNavbar` in
`<% if logged_in? && current_user.solana_connected? %>`, and `:1420` wraps
`render "shared/phantom_watcher"` in the identical condition. So one DB fact
decides "show the connected check", "fetch on-chain values", *and* "watch for
wallet changes at all" — which is exactly why the read-only mode of requirement 5
has nowhere to attach today. Slice 9 must re-key **both** sites.

### Defect B — the disconnect signal is swallowed *and* never subscribed (CONFIRMED)

Two layers, not one:

1. `app/javascript/solana_stores.js:179` — `_handleAccountChanged` opens
   `if (!publicKey) return;`. The comment above it is right that a null event must
   not log the user out; the code then does nothing at all.
2. **The `disconnect` event is never listened for.** `grep -rn "'disconnect'"
   app/javascript/ app/views/` returns **no listeners** — only
   `PhantomProvider.disconnect()` (`wallet_provider.js:118`), the outbound call.
   `solana_stores.js:116` subscribes to `accountChanged` and nothing else.

A correction to the brief's framing: the store does **not** already know
`isConnected` — it has no such field, and `PhantomProvider` exposes no such
accessor. What it *can* cheaply derive is `PhantomProvider.isAvailable() &&
!!PhantomProvider.publicKey`. The brief's conclusion still holds: **A and B are
one fix.** The indicator needs a live signal, and the null `accountChanged` (plus
a `disconnect` subscription) is the natural thing to drive it. Split them and the
indicator ships with nothing to update it.

### Defect C — switching to a never-connected Phantom account (CONFIRMED UNTESTED)

No spec covers it. The nearest are `e2e/wallet_session_switch.spec.js` and
`e2e/wallet_changed_card_scope.spec.js`, both of which switch between *connected*
accounts. Phantom disconnects the site when the user selects an account that has
never approved it, which produces a null `accountChanged` — swallowed by B.
**Expected observable today: complete silence.** Slice 8 verifies before fixing.

---

## 4. The target design

### 4.1 One new concept: `WalletSession`

A single client-side object that owns the live-signer answer and nothing else.
It is the store the whole UI asks, and it is the only thing that talks to a
provider.

```
$store.walletSession
  ├── signerAvailable : bool   // provider present AND unlocked AND connected
  ├── signerAddress   : string // the pubkey the provider will actually sign with
  ├── linkedAddress   : string // server truth (User#web3_solana_address)
  ├── providerName    : string // the brand recorded at auth (User#web3_wallet_provider)
  ├── state           : 'live' | 'degraded' | 'mismatched' | 'web2' | 'guest'
  └── lastSeenAt      : epoch ms
```

`state` is derived, never assigned:

| `state` | Condition | UI contract |
|---|---|---|
| `guest` | `!session.loggedIn` | Sign-in affordances |
| `web2` | `session.mode !== 'web3'` | Managed-wallet flows; never probe Phantom |
| `live` | web3 && `signerAvailable` && `signerAddress === linkedAddress` | Everything enabled. **Green check here, and only here.** |
| `mismatched` | web3 && `signerAvailable` && `signerAddress !== linkedAddress` | The existing blocking `wallet-changed` handoff |
| `degraded` | web3 && `!signerAvailable` | **Read-only** — see §4.3 |

**Requirement 1** (both lanes first-class): `web2` is a peer state, not an absence.
**Requirement 3** (record which wallet authenticated): already served by
`User#web3_wallet_provider` (`user.rb:353`, refreshed on every re-auth —
`solana_stores.js:274`); `WalletSession` surfaces it as `providerName` so the
adapter registry resolves the *same* brand that signed, rather than `detect()`'s
first hit.

**Alpine-proxy discipline (the trap):** `WalletSession` holds **only primitives**.
The provider object stays in a module-closure variable, exactly as
`solana_stores.js:31` does today. No refactor may put a provider, a keypair, or
any object destined for an identity comparison on a store. Slice 1's test harness
wraps stores in a memoised `Proxy` so a harness cannot pass against broken code —
`test/lib/wallet_account_change_js_test.rb:60` already does this and is the pattern
to extend.

### 4.2 Requirement 4 — the wallet-change reflex

Three inputs feed `WalletSession`, all through one reducer:

1. `accountChanged(publicKey)` — **including `null`**. A concrete key sets
   `signerAddress` and recomputes `state`; a null sets `signerAvailable = false`
   and moves to `degraded`. The current early return (`solana_stores.js:179`) is
   deleted; the "do not log out" intent it protects is preserved by the fact that
   `degraded` never touches the Rails session.
2. `disconnect` — **newly subscribed**, same reducer path as a null `accountChanged`.
3. `focus` / `wallet-provider:registered` / the 40×100ms discovery window —
   unchanged reconcile, now writing through the reducer instead of directly.

`mismatched` keeps today's blocking handoff (`_notifySwitch` → `wallet-changed`
modal → `_reauth`), including the single-visible-tab nonce guard at `:253`, which
is load-bearing and must survive the refactor untouched.

### 4.3 Requirement 5 — the read-only degradation rule

**The rule, stated once:** *reading on-chain state needs no signer; writing does.*

| Capability | Needs a signer | Behaviour in `degraded` |
|---|---|---|
| Balance / seeds / token count display | No — server-side RPC by address | **Works.** Continues to hydrate |
| Contest browsing, standings, entries | No | Works |
| Entering a contest | Yes | Blocked with `reason: 'signer_required'` |
| Changing a username | Yes | Blocked with `reason: 'signer_required'` |
| Withdrawal / off-ramp | Yes | Blocked with `reason: 'signer_required'` |

Two concrete changes carry it:

- **Hydration stops keying on the signer.** `layout:105`'s
  `current_user.solana_connected?` gate is the wrong question; the right one is
  "does this account have an address to read". They coincide today, which is why
  swapping the predicate for an explicit `user.solana_address.present?` is a
  behaviour-preserving rename that *makes the degraded case work for free* — the
  server reads by address and never needs the browser's signer.
- **`eligibilityBlocker` gains one gate**, ahead of the funding checks and behind
  the wallet-setup check: `if (mode === 'web3' && !walletSession.signerAvailable)
  return { reason: 'signer_required' }`. It pops a "reconnect your wallet" card
  instead of letting the hold run into a failed `signTransaction`.

Authentication becomes a problem **only at the moment of a web3 task** — which is
requirement 5, verbatim.

### 4.4 Requirement 6 — logout is definitive

Replace both deny-lists with an allow-list, on both sides:

- **Server:** `SessionsController#destroy` calls **`reset_session`** after
  capturing the impersonation audit row and destroying the cart. Anything that
  must survive logout (nothing does today) is explicitly re-set afterwards. This
  deletes the two hand-maintained key lists and the double-delete of
  `session_token` / `onchain`.
- **Client:** one exported `wipeClientState()` — `localStorage.clear()`,
  `sessionStorage.clear()`, re-init of every Alpine store to its declared
  defaults, `BroadcastChannel('tm-session')` post so sibling tabs wipe too. It
  runs on the logout link (both call sites, via a shared helper — not two copies
  of an `onclick`) and on a `401` from `session_state`.
- `inviter_slug` is the one key with a plausible claim to survive. **It should
  not.** It is attribution for the *person*, and logout means "start from scratch";
  a `?ref=` in the URL re-establishes it in one line (`layout:141-149`).

### 4.5 Requirement 7 — the refresh contract

One exported function, two triggers.

```
refreshWalletData({ reason }) → Promise<WalletData|null>
```

- **Source:** one endpoint. `GET /account/session_refresh` absorbs
  `/admin/usdc_balance` (§2.4) and gains `username`. `/admin/usdc_balance` becomes
  a thin deprecated alias, then goes.
- **Payload:** `usdc`, `usdt`, `sol`, `tokens`, `seeds`, `level`, `toward_next`,
  `progress`, `level_up_token_pending`, **`username`**, and a
  **`generation`** counter so a slow response can never overwrite a newer one.
- **`nil` means unknown, everywhere.** The `.to_i` at `accounts_controller.rb:63`
  is deleted; `seeds: nil` is emitted as `null` exactly as the balances are, and
  every client writer restores the "leave the prior value" rule. This alone kills
  §2.3's zeroing bug.
- **(a) On demand:** every on-chain success path, the `walletRefresh()` button,
  and the `wallet-changed` re-auth all call it with a `reason`.
- **(b) Heartbeat:** a **60s interval**, owned in one place, that:
  - starts only when `session.loggedIn && user has an address` (works in
    `degraded` — reads need no signer);
  - **pauses when `document.hidden`** and fires once immediately on becoming
    visible, so a backgrounded tab does not bill RPCs for an absent user;
  - is **the only** `setInterval` for wallet data (today there are none —
    confirmed: the only non-debug intervals are short-lived pollers, none of them
    a wallet heartbeat);
  - de-dupes against an in-flight call via the existing `lockedFetch` lock
    (`solana_utils.js:5`).

This is what makes "the user moved USDC in another dApp" observable.

### 4.6 The storage façade

One module owns all browser storage. No `localStorage` literal survives outside it.

```
storage.get(key) / set(key, value) / remove(key) / clearAll()
KEYS = { INVITER_SLUG: 'tm.v1.inviter_slug', … }
```

- **One namespace: `tm.v1.`** — so `clearAll()` can be prefix-scoped if a future
  requirement needs it, and so the phantom-deeplink set is a *derived* list rather
  than the two hand-written enumerations of §2.1.
- **Scope is declared per key**, not chosen at the call site — which is what
  eliminates the `'seedsNavbar'` / `"seedsNavbar"` quoting inconsistency by
  construction.
- `seedsNavbar` gets **one writer** behind a `max-wins` merge (writer 4's rule,
  promoted to the rule) — see slice 6.

---

## 5. The slice plan

Ordered. Slices 1-6 are **behaviour-preserving**; 7-11 **change behaviour**.
Each is independently reviewable and independently shippable.

`docs` shape carries no tiers. `ui-only` owes `[component]`. `ui+db` owes
`[unit] [component] [integration] [e2e]`. `backend` and `library` owe
`[unit] [integration]`. (`config/feature_shapes.yml`, re-read 2026-08-25.)

| # | Slice | Shape | Tiers owed | Behaviour |
|---|---|---|---|---|
| 1 | **Storage façade + key constants.** Introduce `app/javascript/storage.js` with `KEYS`, `get/set/remove/clearAll`, scope-per-key. Route all 13 writer files through it. Keys keep their **current names** — no renaming in this slice. | `ui+db` | `[unit]` façade incl. quota/private-mode failure · `[component]` seeds bar + wallet-setup modal still read/write · `[integration]` phantom-deeplink round trip · `[e2e]` `wallet_setup.spec.js` + `cart_survives_turbo_restore.spec.js` green | **Preserving** |
| 2 | **Delete the `ALL_KEYS` duplicate.** `phantom_callback.html.erb` derives its cleanup set from the façade's `PHANTOM_DL` group. Fixes the `phantom_dl_user_id` leak (§2.1) as a side effect. | `ui+db` | `[unit]` derived set equals the written set · `[integration]` callback leaves zero `phantom_dl_*` behind · `[e2e]` `wallet_sign_in.spec.js` | **Preserving** (plus one leak closed) |
| 3 | **Extract the layout's inline stores to modules.** Move `session`, `solanaModal`, `sidebars` out of `application.html.erb`'s 1,058 inline lines into `app/javascript/`, preserving `alpine:init` ordering. `modal_preview.html.erb` imports the **same** module instead of its drifted copy (§2.2). | `ui-only` | `[component]` every store registers with its full field set under both layouts; `/admin/modals` preview renders the six previously-missing fields | **Preserving** (the preview gains six fields it should always have had) |
| 4 | **Collapse the two hydrate endpoints.** `/account/session_refresh` absorbs `balance` + `seeds_to_next`; `/admin/usdc_balance` becomes a deprecated alias delegating to it. Delete the `.to_i` at `accounts_controller.rb:63` — `seeds: nil` stays null. | `backend` | `[unit]` payload shape incl. every-field-null flake case · `[integration]` both routes return identical JSON for the same user | **Preserving** at the endpoint; **fixes** the seeds-zeroing bug |
| 5 | **One balance-slot rule.** `refreshSession` calls `applyBalanceSlotRule()`; delete the inlined copy (`solana_utils.js:268-281`). Unify the null-paint rule with `refreshBalance`'s. | `ui-only` | `[component]` `$0`+token → "✨ Free Entry" label active after **both** `refreshSession` and `refreshBalance`; single-sided null paints identically | **Preserving** (removes a latent divergence) |
| 6 | **One `seedsNavbar` writer, max-wins.** Route all five writers through `storage.mergeSeeds()` carrying writer 4's `serverTotal > cacheTotal` rule. | `ui+db` | `[unit]` merge never lowers the cached total; null total is a no-op · `[component]` seeds bar · `[integration]` state-fanout level-up path · `[e2e]` `quest_ladder_web3.spec.js` | **Preserving** (adopts the strictest existing rule) |
| 7 | **`WalletSession` store + the disconnect reflex.** New store per §4.1; subscribe `disconnect`; delete the `if (!publicKey) return` early return (`solana_stores.js:179`) in favour of the reducer. **Defects A and B ship together here** — the green check at `_solana_wallet_section.html.erb:46` re-keys from `user.solana_connected?` to `walletSession.state === 'live'`. | `ui+db` | `[unit]` reducer truth table, in the memoised-`Proxy` Node harness · `[component]` indicator renders live/degraded/mismatched · `[integration]` re-auth still single-tab-guarded · `[e2e]` new `wallet_disconnect.spec.js` + existing `wallet_session_switch.spec.js` | **CHANGES** — the check now reflects live connectivity |
| 8 | **Defect C — never-connected account switch.** Write the spec **first**, confirm today's silence, then confirm slice 7 fixed it. | `ui+db` | `[e2e]` switch to an unapproved account → `degraded`, indicator greys, no logout · `[unit]` reducer case | **Preserving** (verification of 7) |
| 9 | **Read-only degradation.** Re-key **both** `layout:105` (hydrate) and `layout:1420` (watcher) from `solana_connected?` to `solana_address.present?`; add the `signer_required` gate to `eligibilityBlocker`; add the reconnect card. | `ui+db` | `[unit]` blocker returns `signer_required` only for web3+`!signerAvailable`, and **after** first-name/age/wallet-setup · `[component]` reconnect card · `[integration]` server `enter` still refuses independently · `[e2e]` delete-the-extension → balances still render, entry blocked | **CHANGES** — requirement 5 |
| 10 | **Definitive logout.** `reset_session` server-side; `wipeClientState()` client-side from one shared helper on both logout links; cross-tab broadcast. | `ui+db` | `[unit]` wipe empties both storages and re-inits every store · `[integration]` no session key survives `destroy` (assert over the full 15-key set) · `[e2e]` log out → log in as user B → zero user-A state · `[component]` both logout links use the shared helper | **CHANGES** — requirement 6 |
| 11 | **Refresh contract + 60s heartbeat.** `refreshWalletData({reason})`; add `username` + `generation` to the payload; hidden-tab-paused heartbeat. | `ui+db` | `[unit]` generation guard drops a stale response; heartbeat pauses on `hidden`, fires once on visible · `[integration]` payload carries username · `[e2e]` balance updates without navigation within ~60s (RPC mocked) | **CHANGES** — requirement 7b |

**Sequencing notes.**
- 1 → 2 and 1 → 6 are hard dependencies (both need the façade).
- 3 is independent of 1/2 and can run in parallel.
- 7 must precede 8, 9 and 11 — all three read `walletSession.signerAvailable`.
- 10 is independent of 7 and can ship any time after 1.
- 4 should precede 11 (one endpoint before adding fields to it).
- **Do not bundle.** Slices 7, 9, 10 and 11 each change user-visible behaviour in
  the auth path; each deserves its own QA stop.

**A trap for slices 1, 2, 6, 8, 9, 10 and 11:** every one adds or moves an e2e
spec, so `config/e2e_lane.yml`'s executed-set counter must be re-derived with
`npx playwright test --list` — never by arithmetic — and **re-derived again after
any merge from `accepted`**. That counter has collided twice in one day.

**And for slice 7 specifically:** the Node harness must wrap stores in a memoised
`Proxy` (`test/lib/wallet_account_change_js_test.rb:60` is the existing pattern).
A harness storing raw objects passes against the broken code. Mutation-check
every new guard, and **verify the mutation actually applied** — a string that does
not match mutates nothing and reads exactly like a blind test.

---

## 6. Migration note — what happens to a returning user

Renaming keys strands whatever is already in a real user's browser. Slice 1
therefore **does not rename anything**: it routes every call site through the
façade while `KEYS` still maps to the current literal strings. Renaming to the
`tm.v1.` namespace is a **separate, later** step, and it needs a read-through
shim.

### The rule

For one release after the rename, `storage.get(key)` reads the new name, falls
back to the legacy name, and **migrates on read** (write new, remove old).
`storage.set` only ever writes the new name. The shim is deleted one release
later.

### Per key, if the rename shipped with no shim

| Key | Blast radius for a user mid-flow |
|---|---|
| **`phantom_dl_*`** | **The dangerous one.** These nine keys are a *live cryptographic handshake*: `phantom_deeplink.js` writes the dapp keypair + nonce, the user leaves for the Phantom mobile app, and `phantom_callback.html.erb` reads them back on return. A rename landing inside that window means the callback reads `null` for `phantom_dl_secret` and cannot decrypt Phantom's response. The user lands on the error path (`phantom_callback.html.erb:89`) and is redirected to `/signin` after 30 seconds. They are not harmed — no session is created, nothing is signed — but the connect attempt is lost and must be restarted. **The read-through shim is mandatory here**, and the shim must cover the whole set including `phantom_dl_user_id` (see §2.1). |
| **`pendingContestEntry`** | **Low.** Written on an external redirect, consumed on return, and already guarded by a 30-minute freshness check (`_turf_totals_board.html.erb:461`) plus a `?picks=` URL fallback that carries the lineup independently of storage (`:441`). A stranded value means one lost saved cart: the user returns to the contest page with an empty cart and re-picks. The `?picks=` path is unaffected because it never touches storage. A shim makes even that invisible. |
| `seedsNavbar` / `seedsLevelUp` | **Cosmetic.** A stranded value means the seeds bar starts from the server value instead of animating from the cache — one render, self-heals on the next hydrate. The level-up confetti for one crossing may not play. |
| `inviter_slug` | **Low, but revenue-adjacent.** A stranded value loses referral attribution for a user who arrived via `?ref=` and had not yet logged in. Not recoverable without the shim (the URL param is stripped at `layout:144`). Include it in the shim. |
| `walletSetupAutoConnect` / `walletSetupReopen` | **Cosmetic.** The wallet-setup modal does not auto-reopen once after a redirect; the user clicks Connect again. |
| `pendingAuthStep` | **Cosmetic.** The auth wizard resumes at its first step instead of mid-flow. |
| `lastUserId` | **Self-healing, but note the side effect.** A stranded `lastUserId` makes the next page load see `current !== last` and run the identity-change purge (`layout:938`) — clearing `seedsNavbar`, `seedsLevelUp` and `phantom_dl_*` for a user who did not change identity. Harmless (they rehydrate), but it means a rename of `lastUserId` **triggers a one-time purge of the deeplink keys for every user**. If `lastUserId` and `phantom_dl_*` are renamed in the same release, that purge can land between a mobile deeplink's outbound leg and its callback. **Rename `lastUserId` in a different release from `phantom_dl_*`.** |

### Recommended migration order

1. Slice 1 ships the façade with **legacy key names** — zero migration risk.
2. A later, separate task adds the read-through shim and flips `KEYS` to `tm.v1.*`
   for everything **except** `lastUserId`.
3. A third task renames `lastUserId`, once the deeplink keys have settled.
4. A fourth deletes the shim.

Slice 10's `wipeClientState()` uses `localStorage.clear()`, which is
namespace-agnostic and therefore correct during and after the migration.

---

## 7. What this audit did not cover

Named so the next reader does not mistake silence for a clean bill.

- **`studio-engine`'s side of the seam.** `SessionContext` and `clear_app_session`
  live in the gem. Slices 4 and 10 may need a gem change; if so, that is a
  `library`-shaped task with consumer-CI in **both** apps, sequenced ahead of the
  turf-monster slice that adopts it.
- **The 60s heartbeat's RPC cost.** Each beat is four Solana RPCs per active
  tab per minute. The hidden-tab pause and the `lockedFetch` de-dupe bound it, but
  the aggregate cost at real concurrency has not been modelled. Slice 11 should
  carry a measurement before it ships.
- **Mobile deeplink parity.** Every reflex in §4.2 is extension-based. The mobile
  deeplink flow has no equivalent of `accountChanged`; what `degraded` means on
  mobile is an open question.
- **Adjacent designed tasks.** `/tasks/patch-phantom-across-adapters` and
  `/tasks/ship-wallet-brand-unknown-mark` both touch `wallet_provider.js` and the
  brand stamp. Slice 7 overlaps them; sequence before starting.
