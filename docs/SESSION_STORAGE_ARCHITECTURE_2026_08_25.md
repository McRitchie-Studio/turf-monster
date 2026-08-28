# Session, Auth & Wallet Storage — Audit and Target Architecture

**Task:** https://mcritchie.studio/tasks/audit-session-storage-architecture
**Measured:** 2026-08-25, against `feat/audit-session-storage-architecture` (branched from `accepted` at `e154fc7`).
**Status:** Phase 1 — audit and proposal. **No refactor has been performed.** Every slice in §5 is unstarted and awaits Mr. McRitchie's approval.

**Revision 2 (2026-08-25).** Review returned revision 1 for an incomplete
inventory, correctly. Three verified gaps, all traceable to one methodology
error: the first pass used **literal-only greps scoped to `app/`**. That
structurally cannot see `session[SESSION_KEY]` (a constant), and it structurally
cannot see engine partials that render into this host. Both axes have been
re-run; §1 counts are re-derived and the slice denominators now match them.
Re-running the engine axis found two further gaps review did not name (a sixth
and seventh Alpine store; a sixth `seedsNavbar` reader), and a material omission
review did name — the `DEBUG_NET` production exposure, now §3.4.

**The exact command set behind §1, so the next reader can reproduce every count:**

```bash
ENGINE=/Users/alex/projects/studio-engine
# browser storage keys — app/ PLUS the engine partials this layout renders
{ grep -rhoE "(localStorage|sessionStorage)\.(setItem|getItem|removeItem)\(['\"][A-Za-z_][A-Za-z_0-9]*['\"]" app/ ;
  grep -rhoE "(localStorage|sessionStorage)\.(setItem|getItem|removeItem)\(['\"][A-Za-z_][A-Za-z_0-9]*['\"]" \
    $ENGINE/app/views/layouts/studio/_head.html.erb \
    $ENGINE/app/views/components/_user_nav.html.erb \
    $ENGINE/app/views/studio/banners/_dev_mode_button.html.erb ; } \
  | sed "s/.*(//" | tr -d "\"'" | sort -u                                  # → 19
# session keys — literals, THEN resolve every constant-keyed write by hand
grep -rhoE "session\[:[a-z_0-9]+\]" app/ lib/ | sed 's/session\[://;s/\]//' | sort -u   # → 15
grep -rnE "session\[[A-Z]|session\.delete\([A-Z]" app/ lib/   # → 2 constants: +wallet_brand +turf_user_id = 17
# writer files — the scope IS the number; state which one you mean
grep -rl "\(localStorage\|sessionStorage\)\.\(setItem\|removeItem\)" app/            # → 13
grep -rl "\(localStorage\|sessionStorage\)\.\(setItem\|removeItem\)" app/ e2e/       # → 17
# inline <script> lines — EXCLUDE src= tags, which revision 1 wrongly counted
awk '/<script/ && !/src=/ {inb=1; next} /<\/script>/ && inb {inb=0; next} inb {n++} END {print n}' \
  app/views/layouts/application.html.erb                                     # → 1034
```

Where the brief's measured starting state has drifted, the drift is noted inline.
**One of the brief's figures was right and revision 1 wrongly rebutted it** — see §1.2.

---

## 0. The idea, in one page

Turf Monster knows four different answers to "does this person have a wallet
right now", and none of them is the true one.

1. **`User#solana_connected?`** — a *database* fact: some wallet address is
   stored on the account. This is what paints the green check.
2. **`SessionContext#mode == :web3`** — a *server session* fact: this session
   proved a wallet signature at some point. This is what the entry gate branches on.
3. **`$store.session.walletConnected`** — a client mirror of answer 1, wearing a
   name that reads like answer 4. Set from the same DB predicate
   (`application_controller.rb:539`).
4. **The browser** — whether Phantom is installed, unlocked, and connected to this
   origin *at this instant*. **Nothing in the app stores or exposes this.**

Fact 4 is the only one that decides whether the next signature will succeed, and
it is the one nobody records. That single gap explains defects A, B and C, the
absence of a read-only mode, and why a wallet switch can go unnoticed.

Underneath that sits a storage layer with no owner: **19** browser keys with no
namespace, **17** files writing them, five different writers for one cache key,
two server endpoints answering the same question with different rounding, and a
logout that clears exactly one key and never calls `reset_session`.

There is also one thing the audit found that is not an architecture problem at
all: the network debug logger ships **enabled by default to production** and
prints wallet signatures and CSRF tokens to every user's console (§3.4). It is
filed as its own bug task, not folded into this plan.

The proposal is one new concept — a **WalletSession** that owns the live-signer
answer — plus one **namespaced storage façade** that owns every key, and one
**refresh contract** that everything hydrates through. Eleven slices, ordered so
the first six preserve behaviour exactly and the last five change it deliberately.

---

## 1. The map — every place session, auth, or wallet state lives

### 1.1 Client — Alpine stores (7)

| Store | Registered at | Kind | Owner of |
|---|---|---|---|
| `session` | `app/views/layouts/application.html.erb:473` (inline, `alpine:init`) | State | Canonical viewer identity + funding hints: `loggedIn`, `mode`, `phantomLinked`, `userId`, `address`, `usdcCents`, `usdtCents`, `tokensAvailable`, `web2UsdcEntry`, `ageGateRequired`, `ageVerified`, `walletSetupRequired`, `firstNameRequired`, `walletConnected` |
| `wallet` | `app/javascript/solana_stores.js:41` (module) | State | Live Phantom watcher: `address`, `watching`, `pendingAddress`, `_provider`, `_reauthing` |
| `modals` | **studio-engine** `app/views/studio/modals/_host.html.erb` (resolved from the gem; see the correction below) | UI | Modal stack |
| `solanaModal` | `app/views/layouts/application.html.erb:612` (inline) | UI façade | Read/write proxy over `modals` for the `onchain-tx` card. Holds no session state. |
| `sidebars` | `app/views/layouts/application.html.erb:370` (inline) | UI | `gearOpen` |
| `theme` | **studio-engine** `app/views/layouts/studio/_head.html.erb:162` | UI | `value` ('dark'/'light'), `isDark`, `toggle()` — persists to the `theme` key |
| `devMode` | **studio-engine** `app/views/layouts/studio/_head.html.erb:161` | UI | A bare boolean seeded from the `devMode` key |

**`theme` and `devMode` were missing from revision 1.** They reach every page
through `app/views/layouts/application.html.erb:873` → `render "layouts/studio/head"`
(also `layouts/landing.html.erb:25` and `layouts/modal_preview.html.erb:123`). An
`app/`-scoped grep cannot see them. They are UI-only and carry no auth state, but
they are browser-persisted state on every page and they belong in a storage
inventory — and §4.4's logout wipe has to make a deliberate decision about them
(see there).

The engine also registers `sidebars` at `components/_link_sidebar.html.erb:36`;
**that partial is not rendered by turf-monster**, so `sidebars` has exactly one
live registration here. Verified, not assumed.

A **second, drifted copy** of `session` and `solanaModal` is registered at
`app/views/layouts/modal_preview.html.erb:63` and `:98` — see §2.2.

**Registration is split four ways** (module / app layout / app-local override of
an engine partial / engine partial), which is worse than the split the brief
flagged. Confirmed, with one correction: the brief listed
`solanaConnectAndVerify`, `postMagicLink` and `fireSuccessConfetti` as inline —
they are, and so are the `session`, `solanaModal` and `sidebars` stores. Only the
`wallet` store loads from a module.

A fourth split worth recording — **CLOSED 2026-08-28 by
`defork-turf-modal-host`.** As written on 2026-08-25 this said: `modals` is
registered from `app/views/studio/modals/_host.html.erb`, a **host-app override
that shadows the engine's own copy** of the same partial, which registers
`modals` too — the same disease as §2.2, two copies of one store kept in step by
hand. That override is DELETED. `modals` now has exactly one registration, in
studio-engine's own host, and this app reaches it through the engine's two
consumer seams (`window.StudioModals.CARD_WIDTHS` and `modals/_host_extras`)
rather than by forking. See `docs/UI_PATTERNS.md` § modal host.

**Do not restore a file at `app/views/studio/modals/_host.html.erb` to "fix" a
modal.** studio-engine is non-isolated, so that path silently wins the lookup and
re-opens exactly this split. `test/views/modal_host_adoption_test.rb` resolves
the host through `lookup_context` and fails if it ever resolves inside this
app's `app/views` again.

The inline block totals **1,034 lines** across `application.html.erb` (of 1,424).
Revision 1 said 1,058; that figure counted the external `<script src=...>` tag
lines at `:52-59` and did not reproduce. The `awk` above excludes them.

### 1.2 Client — browser storage keys (19)

**19 keys: 17 written from `app/`, plus `theme` and `devMode` from the engine
partials this layout renders.** Revision 1 said 18 and was wrong twice over — it
missed the two engine keys, and its 18th row was not a key at all but a duplicate
`seedsNavbar` quoting note (that note now sits below the table, where it belongs).

**Writer-file counts depend entirely on scope, so the scope is stated with the
number:** **13** files in `app/`, **17** in `app/` + `e2e/`, **19** including the
two engine partials.

**The brief was right and revision 1 wrongly rebutted it.** Revision 1 claimed the
brief's "17 files write" had counted readers; it had not. 17 is the correct count
on the `app/` + `e2e/` scope. Revision 1 compared its own `app/`-only 13 against
the brief's 17 and called the difference an error in the brief. It was a
difference in scope, and the rebuttal is withdrawn.

| Key | Store | Writer(s) — the owner | Reader(s) | Lifetime rule |
|---|---|---|---|---|
| `inviter_slug` | local | `layouts/application.html.erb:143` | same file `:164` | Cleared on successful `PATCH /account/set_inviter` (`:171`) |
| `lastUserId` | local | `layouts/application.html.erb:952` | same file `:936` | Identity-change sentinel; drives the purge below |
| `pendingAuthStep` | session | **NONE — ORPHANED. See below.** | `:397` reads | `:400`, `:424` remove |
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
| **`theme`** | local | **studio-engine** `layouts/studio/_head.html.erb:169` | same file `:3` (pre-paint FOUC guard) and `:163` | **Never cleared.** Survives logout and the identity purge |
| **`devMode`** | local | **studio-engine** `studio/banners/_dev_mode_button.html.erb:4` | `layouts/studio/_head.html.erb:161` | **Never cleared.** Survives logout and the identity purge |

**`pendingAuthStep` is orphaned — a revision-1 fabrication, corrected.** Revision 1
listed `:400` and `:424` in the column headed "Writer(s) — the owner". Both are
`removeItem`. Repo-wide the key has **zero `setItem`** — verified across `app/`,
`e2e/`, `test/` *and* studio-engine. So the `:397` read can never return non-null,
and the auth-step resume path it feeds is **dead code that revision 1's map
presented as a live flow**. Recorded as a finding in its own right: either the
writer was removed and the reader left behind, or it never existed. Slice 1 should
delete the reader rather than route a dead key through the façade.

**Quoting is ad hoc** (not a key, so not a table row): `seedsNavbar` is written
with `'…'` in `solana_utils.js` and `contests/show.html.erb`, `"…"` in
`state_fanout.js` and `seeds_bar.js`. Confirms the brief's read.

**No namespace convention exists** except `phantom_dl_*`. There is no shared
constant file; every key is a string literal at its use site — which is precisely
why an inventory built from literal greps could miss two of them.

### 1.3 Client — cookies

The app writes exactly one non-Rails cookie: `cookies[:reference]` (9 sites,
referral attribution). The Rails session cookie is the only auth-bearing one.

### 1.4 Server — session keys (17)

Written across controllers/services:

`wallet_setup`, `wallet_setup_prompt`, `web3_step_up_prompt`, `onboarding_prompt`,
`onboarding_skipped_first_name`, `true_admin_id`, `impersonated_user_id`,
`impersonation_started_at`, `solana_nonce`, `solana_nonce_at`, `session_token`,
`onchain`, `pending_google_link`, `return_to`, `oauth_popup`, **`wallet_brand`**,
**`turf_user_id`**.

| Key | Written | Cleared | Read |
|---|---|---|---|
| **`wallet_brand`** | `solana/current_wallet.rb:50` via `CurrentWallet.remember`, called from `solana_sessions_controller.rb:75` on verify | `current_wallet.rb:55` via `CurrentWallet.forget`, called from `application_controller.rb:65` (login) and `:72` (logout) | `current_wallet.rb:41` via `CurrentWallet.from_session`, memoised at `application_controller.rb:79` |
| **`turf_user_id`** | **studio-engine** `concerns/studio/error_handling.rb:31` (`set_app_session`) | same file `:65` (`clear_app_session`) — the first of §2.6's 3 | `error_handling.rb:26`, `application_controller.rb:362` (`true_user`), `config/routes.rb:14`, `rack_attack.rb:103` |

**`wallet_brand` was missing from revision 1** — the wallet-identity session key,
absent from a wallet audit. It is defined as
`SESSION_KEY = :wallet_brand` (`app/services/solana/current_wallet.rb:36`), so a
`session[:literal]` grep cannot see it — and it is **one of two** such keys. The
second matters more: `Studio.session_key`, configured to `:turf_user_id`
(`config/initializers/studio.rb:44`), is the **primary authentication key**, written
by the engine and never a literal in `app/`/`lib/` — revision 2 missed it exactly as
revision 1 missed `wallet_brand`. A third constant,
`Studio::FIRST_NAME_SKIP_SESSION_KEY` (`studio-engine/lib/studio.rb:343`), resolves
to `onboarding_skipped_first_name`, already counted. All three resolved by hand.
Scope: these 17 are reachable from `app/`+`lib/`; the engine writes `sso_*`/`geo_*`
into the same cookie (§2.6) and slice 10 must decide if its assertion covers them.

Owner: `SessionsController` / `SolanaSessionsController` / `ApplicationController`
/ `Solana::CurrentWallet`. The authoritative web3 flag is `session[:onchain]`,
read through `ApplicationController#onchain_session?`
(`app/controllers/application_controller.rb:473`) — which **returns `false` while
impersonating** (OPSEC-046), so an admin viewing another account is never `:web3`
regardless of their own session.

### 1.5 Server — the user record

`app/models/user.rb`:

| Field / method | Line | Meaning |
|---|---|---|
| `web2_solana_address` | `:64` | Custodial address (managed keypair) |
| `web3_solana_address` | `:65` | Self-custody address (Phantom) |
| `web3_wallet_provider` | `:353` | **The brand that authenticated** — requirement 3 is *already partly implemented* |
| `solana_address` | `:504` | `web3 \|\| web2` — prefers web3 unconditionally (as the brief said) |
| `solana_connected?` | `:303` | `web2.present? \|\| web3.present?` — the DB fact behind defect A |
| `phantom_wallet?` | `:311` | `web3.present?` |
| `managed_wallet?` | `:307` | `web2.present?` |
| `wallet_kind` | `:320` | `:phantom` / `:managed` / `:none` |
| `generate_managed_wallet!` | `:523` | `after_create :89`; **early-returns when `AppFlags.web3_only_onboarding?`**, which defaults **on** (`app/services/app_flags.rb:133`) |

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
3. `pageshow` (bfcache) → `rehydrateSession()` (`layout:855`)
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

Readers number **six**, not the five revision 1 listed: studio-engine's
`app/views/components/_user_nav.html.erb:123` also reads `seedsNavbar`, and
reaches this app through `app/views/layouts/_navbar.html.erb:103`. Found by the
engine axis, not named in review.

**The disagreement:** writer 4 exists specifically to stop a stale server value
from lowering the cache. Writers 3 and 5 have no such guard, and writer 3 can
write a *zero*:

`accounts_controller.rb:64` — `seeds = hydrate[:seeds].to_i`. On an RPC flake
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
later (`:285`) and re-applies the real rule over the top. It is a second
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
  **One key of nineteen.** The gear-sidebar link carries `data: { turbo: false }`;
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

### 2.7 CONFIRMED — Four answers to "is there a live signer", none of them live

| Answer | Source | Actually means |
|---|---|---|
| `user.solana_connected?` | `user.rb:303` (DB) | An address is stored on the account |
| `session.mode === 'web3'` | `SessionContext#mode` ← `session[:onchain]` | This session signed *at some point* |
| **`$store.session.walletConnected`** | `application_controller.rb:539` — set to `current_user&.solana_connected?`, **the same DB predicate** | Branched on at `modals/_wallet_setup.html.erb:564` and `:570` |
| — | — | **Nothing** records "Phantom is installed, unlocked, and connected right now" |

**`walletConnected` is the worst-named of the four** and revision 1 missed it. It
is a client mirror of the *database* fact wearing a name that reads like live
browser connectivity. Left alone, it would sit beside slice 7's
`walletSession.signerAvailable` meaning something entirely different. **It joins
the re-key list** (slice 7): rename it to `walletHasAddress` — the question its
two call sites actually ask, which is "can an entry-token rail work for this
account at all".

### 2.8 CONFIRMED — Two facts about which wallet authenticated, and no stated precedence

- **Durable:** `User#web3_wallet_provider` (`user.rb:353`), the column, refreshed on
  every re-auth (`solana_stores.js:274`).
- **Per-session:** `session[:wallet_brand]` via `Solana::CurrentWallet`
  (`current_wallet.rb:36`), written at verify (`solana_sessions_controller.rb:75`),
  forgotten at login and logout (`application_controller.rb:65`, `:72`).

`solana_sessions_controller.rb:73-74` spells the duality out in a comment. They can
disagree by construction: an account whose column says `phantom` opens a session
that never verified a wallet, and `wallet_brand` is absent while the column is not.
Revision 1 answered requirement 3 with "already served by `User#web3_wallet_provider`"
and never mentioned the session half — see §4.1 for which one `WalletSession.providerName`
must read, and why.

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

### 3.4 The `DEBUG_NET` production exposure (CONFIRMED — omitted from revision 1)

Not one of the three defects in the brief. Found by review, verified here, and
recorded in the body rather than in §7 because it was a **look-and-miss**, not a
scoping decision: revision 1 had `debug_logger.js` open — §4.5 counts its two
timers at `:157` and `:199` — and did not read what the file logs.

**The mechanism, end to end:**

| Step | Evidence |
|---|---|
| The logger defaults **on** | `app/javascript/debug_logger.js:7` — `if (window.DEBUG_NET === undefined) window.DEBUG_NET = true`. Its own header says "Defaults to enabled." |
| It ships to every browser | `config/importmap.rb:5` pins it; `app/javascript/application.js:3` imports it unconditionally |
| No environment guard exists | `grep -rn "DEBUG_NET" app/ config/` outside the file itself returns **nothing** |
| It prints request bodies | `:52` — `console.log('request:', _trunc(reqBody, 1500))` |
| It prints response bodies | `:53` — `console.log('response:', _trunc(body, 1500))` |
| The wallet-verify body carries auth material | `layouts/application.html.erb:332` — `JSON.stringify({ message, signature: signatureB58, pubkey, age_attestation, wallet_provider })`. Both the SIWS message and the full base58 signature are well inside the 1,500-char truncation |
| It repeats | On first sign-in, and again on **every** `_reauth` (`solana_stores.js:269`) — which slice 7 makes *more* frequent, since a wallet switch drives a re-auth |
| Responses leak a live CSRF token | `accounts_controller.rb:90` — `session_state` returns `csrf: form_authenticity_token`, printed by `:53` on every visibility rehydrate |

**Severity, stated honestly.** The signature is not a replayable credential: the
nonce is delete-before-verify (OPSEC-018, `sessions_controller.rb` + the
`solana_nonce` lifecycle), so a captured signature verifies against a nonce that
is already gone. The CSRF token is the sharper end — it is live, it rotates into
the page, and it is printed in clear. Either way, printing authentication material
and CSRF tokens to every production console is wrong, and an audit that silently
passed over it would be worth less than one that says so.

**This is a code fix and must NOT ride this docs PR.** Filed as its own bug task:
**https://mcritchie.studio/tasks/guard-debug-net-logging** (`bug` / `ui+db`).
The minimum fix is an environment guard on the default; the fuller fix is
redacting `signature`, `message` and `csrf` from the logged bodies, since a
developer running with `DEBUG_NET=true` locally should not print them either.

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
**Requirement 3** (record which wallet authenticated) is served by **two** facts,
not one — see §2.8. `providerName` must read **`session[:wallet_brand]` first,
falling back to `User#web3_wallet_provider`**, and the order is load-bearing:

- `wallet_brand` answers *"which brand signed into THIS session"* — exactly the
  question `_preferredProvider()` (`solana_stores.js:93`) asks when it resolves an
  adapter, because the adapter must be the one that can sign *now*.
- The column answers *"which brand does this ACCOUNT use"* — the durable fact,
  correct for a returning user and for server-side rendering, but stale for a
  session that authenticated with a different wallet.

Reading only the column (revision 1's answer) resolves the wrong adapter for a
user who owns two wallets and signed in with the second. The server already
exposes the session fact through `ApplicationController#current_wallet`
(`:79`); serialising it into `#session-context` is a one-line addition and is
part of slice 7.

**Alpine-proxy discipline (the trap) — restated correctly.** Revision 1 wrote the
rule as "no refactor may put a provider on a store". That is **wrong and would
mislead slice 7**: `_provider` *is* a store field today (`solana_stores.js:45`,
assigned at `:112`), and §1.1 correctly lists it. The code's own comment at
`:29-30` gives the real rule, and it is a rule about **comparison, not storage**:

> `_provider` stays on the store as a debugging mirror (it is what a console probe
> reads); **NOTHING may compare against it.**

So: **never-compare, not never-store.** Identity lives in the module closure
(`watched`, `:31`) and the `WeakSet` (`bound`, `:37`), because
`Alpine.store(name, obj)` returns a reactive **Proxy** and reading an object-valued
property back hands you a proxy *of* the value — `proxy === raw` is false forever.
`WalletSession` may keep a debugging mirror on the same terms; every identity check
must read the closure. Slice 1's test harness
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
- `inviter_slug` is the one *app* key with a plausible claim to survive. **It should
  not.** It is attribution for the *person*, and logout means "start from scratch";
  a `?ref=` in the URL re-establishes it in one line (`layout:141-149`).
- **`theme` and `devMode` are the deliberate exceptions, and the only two.** They
  are device preferences, not session state: a user who logs out should not have
  the site flip from dark to light. `localStorage.clear()` would take them, so
  `wipeClientState()` reads both, clears, and restores them — and that
  read/clear/restore is the *whole* allow-list, written in one place so the next
  key added has to argue for itself. Slice 10 owes a unit test asserting exactly
  two keys survive.

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
- **`nil` means unknown, everywhere.** The `.to_i` at `accounts_controller.rb:64`
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
    a wallet heartbeat; the two debug intervals are `debug_logger.js:157` and
    `:199` — see §3.4, which is what that file turned out to be hiding);
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
| 1 | **Storage façade + key constants.** Introduce `app/javascript/storage.js` with `KEYS`, `get/set/remove/clearAll`, scope-per-key. Route **all 17 `app/`+`e2e/` writer files** through it (13 in `app/` alone — see §1.2 on scope), covering **all 19 keys**. `theme`/`devMode` are engine-owned: the façade must *know* them (slice 10 restores them) but must not write them. Delete the orphaned `pendingAuthStep` reader rather than route a dead key. Keys keep their **current names** — no renaming in this slice. | `ui+db` | `[unit]` façade incl. quota/private-mode failure · `[component]` seeds bar + wallet-setup modal still read/write · `[integration]` phantom-deeplink round trip · `[e2e]` `wallet_setup.spec.js` + `cart_survives_turbo_restore.spec.js` green | **Preserving** |
| 2 | **Delete the `ALL_KEYS` duplicate.** `phantom_callback.html.erb` derives its cleanup set from the façade's `PHANTOM_DL` group. Fixes the `phantom_dl_user_id` leak (§2.1) as a side effect. | `ui+db` | `[unit]` derived set equals the written set · `[integration]` callback leaves zero `phantom_dl_*` behind · `[e2e]` `wallet_sign_in.spec.js` | **Preserving** (plus one leak closed) |
| 3 | **Extract the layout's inline stores to modules.** Move `session`, `solanaModal`, `sidebars` out of `application.html.erb`'s 1,034 inline lines into `app/javascript/`, preserving `alpine:init` ordering. `modal_preview.html.erb` imports the **same** module instead of its drifted copy (§2.2). | `ui-only` | `[component]` every store registers with its full field set under both layouts; `/admin/modals` preview renders the six previously-missing fields | **Preserving** (the preview gains six fields it should always have had) |
| 4 | **Collapse the two hydrate endpoints.** `/account/session_refresh` absorbs `balance` + `seeds_to_next`; `/admin/usdc_balance` becomes a deprecated alias delegating to it. Delete the `.to_i` at `accounts_controller.rb:64` — `seeds: nil` stays null. | `backend` | `[unit]` payload shape incl. every-field-null flake case · `[integration]` both routes return identical JSON for the same user | **Preserving** at the endpoint; **fixes** the seeds-zeroing bug |
| 5 | **One balance-slot rule.** `refreshSession` calls `applyBalanceSlotRule()`; delete the inlined copy (`solana_utils.js:268-281`). Unify the null-paint rule with `refreshBalance`'s. | `ui-only` | `[component]` `$0`+token → "✨ Free Entry" label active after **both** `refreshSession` and `refreshBalance`; single-sided null paints identically | **Preserving** (removes a latent divergence) |
| 6 | **One `seedsNavbar` writer, max-wins.** Route all five writers through `storage.mergeSeeds()` carrying writer 4's `serverTotal > cacheTotal` rule. | `ui+db` | `[unit]` merge never lowers the cached total; null total is a no-op · `[component]` seeds bar · `[integration]` state-fanout level-up path · `[e2e]` `quest_ladder_web3.spec.js` | **Preserving** (adopts the strictest existing rule) |
| 7 | **`WalletSession` store + the disconnect reflex.** New store per §4.1; subscribe `disconnect`; delete the `if (!publicKey) return` early return (`solana_stores.js:179`) in favour of the reducer. **Defects A and B ship together here** — the green check at `_solana_wallet_section.html.erb:46` re-keys from `user.solana_connected?` to `walletSession.state === 'live'`. Also: serialise `session[:wallet_brand]` into `#session-context` so `providerName` reads the session fact first (§4.1), and **rename `$store.session.walletConnected` → `walletHasAddress`** (`application_controller.rb:539`, `modals/_wallet_setup.html.erb:564`, `:570`) before its name collides with `signerAvailable` (§2.7). **Extend `e2e/phantom-mock.js` first** — see the note below the table. | `ui+db` | `[unit]` reducer truth table, in the memoised-`Proxy` Node harness · `[component]` indicator renders live/degraded/mismatched · `[integration]` re-auth still single-tab-guarded · `[e2e]` new `wallet_disconnect.spec.js` + existing `wallet_session_switch.spec.js` | **CHANGES** — the check now reflects live connectivity |
| 8 | **Defect C — never-connected account switch.** Write the spec **first**, confirm today's silence, then confirm slice 7 fixed it. **Blocked on the mock change in slice 7.** | `ui+db` | `[e2e]` switch to an unapproved account → `degraded`, indicator greys, no logout · `[unit]` reducer case | **Preserving** (verification of 7) |
| 9 | **Read-only degradation.** Re-key **four** sites, not two: `layout:105` (hydrate), `layout:1420` (watcher), and the **server-side twins** `accounts_controller.rb:62` and `admin_controller.rb:405`, all from `solana_connected?` to `solana_address.present?`. Miss the server pair and the client asks for a hydrate the server refuses to compute, so degraded mode renders zeros instead of balances. add the `signer_required` gate to `eligibilityBlocker`; add the reconnect card. | `ui+db` | `[unit]` blocker returns `signer_required` only for web3+`!signerAvailable`, and **after** first-name/age/wallet-setup · `[component]` reconnect card · `[integration]` server `enter` still refuses independently · `[e2e]` delete-the-extension → balances still render, entry blocked | **CHANGES** — requirement 5 |
| 10 | **Definitive logout.** `reset_session` server-side; `wipeClientState()` client-side from one shared helper on both logout links; cross-tab broadcast. | `ui+db` | `[unit]` wipe empties both storages and re-inits every store · `[integration]` no session key survives `destroy` (assert over the full **17**-key set, `wallet_brand` and `turf_user_id` included) · `[unit]` exactly two browser keys survive the wipe (`theme`, `devMode`) · `[e2e]` log out → log in as user B → zero user-A state · `[component]` both logout links use the shared helper | **CHANGES** — requirement 6 |
| 11 | **Refresh contract + 60s heartbeat.** `refreshWalletData({reason})`; add `username` + `generation` to the payload; hidden-tab-paused heartbeat. | `ui+db` | `[unit]` generation guard drops a stale response; heartbeat pauses on `hidden`, fires once on visible · `[integration]` payload carries username · `[e2e]` balance updates without navigation within ~60s (RPC mocked) | **CHANGES** — requirement 7b |

**Slices 7 and 8 are blocked on a mock change.** `e2e/phantom-mock.js` cannot
express the states they need: `disconnect()` at `:112-113` sets
`isConnected = false` and **emits no event at all**, and `__switchAccount` (`:140`)
emits a null only when explicitly passed `transientNull`. A spec written against
today's mock would go green against the broken code — the exact failure mode the
brief warns about. **Extend the mock as the opening commit of slice 7:**
`disconnect()` must emit, and a `__switchToUnapprovedAccount()` helper must produce
the null-then-site-disconnect sequence Phantom actually produces. Then
mutation-check both, and **verify the mutation applied** before believing either.

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
- **The 60s heartbeat's cost — and it is threads, not only RPC spend.**
  `ApplicationController#fetch_navbar_hydrate` (`:619`) spawns **three raw
  `Thread.new`** per call (`:623` balances, `:632` seeds, `:646` tokens). At 60s ×
  N active tabs that is sustained thread churn on a Puma worker, which is the
  sharper constraint — RPC spend is merely money. The hidden-tab pause and the
  `lockedFetch` de-dupe bound it; the aggregate has not been modelled. Slice 11
  must carry a measurement, and should consider whether the heartbeat wants a
  cheaper endpoint than the full three-thread fan-out.
- **Mobile deeplink parity.** Every reflex in §4.2 is extension-based. The mobile
  deeplink flow has no equivalent of `accountChanged`; what `degraded` means on
  mobile is an open question.
- **Adjacent tasks, re-checked 2026-08-25.**
  `/tasks/patch-phantom-across-adapters` is **`archived`**, not `designed` as the
  brief had it — its finding (that `walletProvider.get('phantom')` returns a
  *different* object before and after Wallet Standard registration) is still live
  and directly concerns slice 7's `_preferredProvider()`. Read it before starting.
  `/tasks/ship-wallet-brand-unknown-mark` is still `designed`, targets
  **studio-engine**, and is blocked on that repo's rubocop gate.

- **Filed out of this audit, deliberately not in this PR:** the `DEBUG_NET`
  production exposure (§3.4) is a code change and rides its own bug task. A docs
  PR must not carry a security fix, and a security fix must not wait on a docs
  review.
