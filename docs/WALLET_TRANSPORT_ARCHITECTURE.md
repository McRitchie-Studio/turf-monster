# Wallet Transport Architecture

**Status:** Design — gem primitives merged (solana-studio PR #35), not yet wired
into turf-monster
**Written:** 2026-09-07
**Task:** https://mcritchie.studio/tasks/wallet-transport-architecture-doc
**Spans:** turf-monster · solana-studio · studio-engine

---

## The problem in one paragraph

`window.walletProvider` models exactly one way of reaching a wallet: an object
injected into the page. That is true of a desktop extension and of a wallet's own
in-app browser, and it is false of every ordinary mobile browser. On iOS Safari
and Android Chrome there is no injected provider, `detect()` returns `null`, and
every call site that does `provider.connect()` throws. The result is not a
degraded mobile experience — it is a **crash with a JavaScript error string in a
user-facing modal**, and it reaches every on-chain flow the app has.

This is not a bug in any one flow. It is a hole in the abstraction, and each
feature built on that abstraction falls through it in turn.

## How it presents

Reported 2026-09-07 from iPhone Safari on `turfmonster.media`, on a contest the
user was entering **with a free entry token**:

```
Preparing Transaction
null is not an object (evaluating 'provider.connect')
```

Confirmed in the LogRocket replay: four identical failures across two page loads
(so not a race), preceded by `Navigated to /auth/phantom/callback?…` — the user
had signed in successfully **through the Phantom deeplink** minutes earlier.

That pairing is the whole diagnosis. Sign-in took the redirect road. Entry tried
to take the injection road. Only one of the two roads is modelled.

## The two transports

| | Inline | Redirect |
|---|---|---|
| Where it works | Desktop extension, Wallet Standard, wallet in-app browser | iOS Safari, Android Chrome |
| Shape | `await provider.op()` resolves in the same page | The page is **destroyed**; the result returns on a callback URL |
| State lives in | JS closures | Must be serialized to survive navigation |
| Modelled today | ✅ `wallet_provider.js` | ❌ one-off, Phantom-only, outside the registry |

A promise cannot survive a navigation. That single fact is what the design has to
be built around; everything below follows from it.

## Current state

### What exists and works

- `app/javascript/wallet_provider.js` — `KeypairProvider`, `PhantomProvider`,
  Wallet Standard discovery (`_wsWallets`), and the `walletProvider` registry.
  `detect()` at `:427` is keypair → Phantom → first Wallet-Standard wallet → `null`.
- `solana-studio/app/views/solana_studio/_phantom_deeplink.html.erb` —
  `startPhantomDeepLink(linkMode, currentUserId)`. Generates an x25519 keypair,
  fetches a nonce, journals to `phantom_dl_*` in localStorage, redirects to
  `https://phantom.app/ul/v1/signIn`.
- `studio-engine/app/views/solana_sessions/phantom_callback.html.erb` — the
  return leg, 344 lines. Reads `phantom_dl_step` at `:149`, decrypts with
  `nacl.box.open.after` at `:205`, POSTs the verify.
- `window.nacl` — loaded from a **blocking, SRI-pinned** tag in
  `app/views/layouts/application.html.erb`. Deliberately not the async
  `deeplink_assets` loader, because the callback reads nacl at parse time.

### The three defects

1. **`startPhantomDeepLink` never enters the provider registry.** It is wired
   straight into the wallet picker. `detect()` cannot return it, so no flow
   except sign-in can use it.
2. **It implements `signIn` only.** `startPhantomDeepLink` has no deeplink
   `signTransaction` or `signAndSendTransaction`. Since this was written,
   solana-studio `accepted` gained both in
   `app/assets/javascripts/solana_studio/redirect_provider.js` (PR #35) — but
   they are **unreleased** (absent from v0.7.0) and no consumer view references
   them, so nothing reaches turf-monster until a solana-studio release plus a
   floor and lock bump.
3. **It is Phantom-hardcoded**, down to the global's name. The picker's
   `canDeepLink` getter tests `typeof startPhantomDeepLink === 'function'`, and
   `showPhantomDeepLink` names Phantom in its identifier.

### A factual correction

`solana-studio/app/views/solana_studio/modals/_wallet_connect.html.erb` stated,
until solana-studio PR #35 corrected the comment hours after this was written:

> *"Solflare and Backpack keep their install rows either way — there is no deep
> link for them, so the download page is still their only path."*

**This is false**, and it is why a Solflare or Backpack user on an iPhone is sent
to a **desktop extension download page** — a silent dead end, arguably worse than
Phantom's crash, which at least produces an error. Verified against vendor docs
2026-09-07; see the adapter table below. **The comment is now fixed; the
behaviour is not** — Solflare and Backpack still get install rows, so the dead
end below is live and this section still describes work to do.

---

## Design

### 1. Transport is a first-class property of a provider

```js
provider.transport  // 'inline' | 'redirect'
```

`detect()` stops returning `null` on mobile and returns the appropriate redirect
provider. Call sites stop needing to know what platform they are on.

### 2. Providers declare capabilities, and the UI gates on them

```js
provider.can('signTransaction')   // → true | false, for THIS wallet on THIS device
```

**This is the single most valuable rule in the document.** Tonight's crash
happened because a button rendered without anyone asking whether the wallet
behind it could do the thing. The Solflare download dead end has the same root
cause. Capability-gated rendering means an unsupported combination shows an
honest message instead of a button that throws — including for wallets that do
not exist yet.

Every entry point that leads to a signature owes this check before it paints.

### 3. Wallet operations become declarative intents with static handlers

The thing that cannot survive a redirect is the closure. So the resume handler
must be registered at page load, keyed by name:

```js
walletOps.define('contest_entry', {
  prepare:  async (ctx)               => { /* POST prepare_entry → { ptx_slug, tx } */ },
  complete: async (ctx, { signature }) => { /* POST confirm_entry */ }
});

// call site — identical on every platform and every wallet:
walletOps.run('contest_entry', { contestId, currency });
```

- **inline transport** — `run` executes prepare → sign → send → complete as one
  async function, exactly as the code does today.
- **redirect transport** — `run` executes prepare, journals the intent, and
  redirects. The callback page reads the journal, looks the op up **by name**,
  and calls `complete`.

Naming the handler statically is the one discipline this imposes on call sites,
and it is the price of surviving page destruction.

### 4. Only a slug crosses the redirect

The entry flow already creates a server-side prepared-transaction record
(`ptx_slug`, via `prepare_entry`, retired by `discard_prepared_entry`). So the
client never carries transaction bytes across the redirect — only a slug. The
journal stays small, non-sensitive, and cheap to validate server-side.

**This is the piece that makes the whole design tractable**, and it already
exists. It was built for blockhash freshness, not for this, but it is exactly the
right shape.

### 5. The send strategy branches per wallet

**Corrected 2026-09-07 against vendor docs — an earlier draft of this document
got this wrong.** Phantom has **deprecated** its `signAndSendTransaction`
deeplink: *"The signAndSendTransaction deeplink is deprecated. Use
signAllTransactions or signTransaction instead."* The page no longer documents
any parameters.

So there is no single mobile send path:

| Wallet | Mobile send |
|---|---|
| Phantom | `signTransaction` deeplink, then **the app broadcasts** — `sendRawTransaction` + `pollConfirmation` stay |
| Solflare | `signAndSendTransaction` — live and recommended, wallet broadcasts |
| Backpack | `signAndSendTransaction` — live and recommended, wallet broadcasts |

The adapter must express both without leaking the choice to call sites. The
hoped-for simplification — deleting the client-side broadcast on mobile — does
**not** apply to Phantom, which is the wallet most of our users hold.

### 6. The journal is a state machine, not a single-shot record

**Corrected 2026-09-07:** an earlier draft said only Phantom lacked the two-hop
problem. In fact **no wallet has a documented `signIn`**, so mobile sign-in is
`connect` **then** `signMessage` — two round trips, two app switches — on all
three. Every wallet also needs an established encrypted session before it signs
anything.

The good news is the other half: **sessions do not expire.** All three state it
explicitly. A session is invalidated only by an explicit disconnect, a wallet
keypair change, a network switch, or an `app_url` blocklisting — so the common
path carries no refresh hop.

```
Sign-in (all three):   [connect] → [signMessage] → done
Transaction, Phantom:  [connect if none] → [signTransaction] → app broadcasts
Transaction, others:   [connect if none] → [signAndSendTransaction] → done
```

So today's `phantom_dl_*` keys generalize to `wallet_dl_*` carrying: the wallet
key, a **step cursor**, the persisted shared secret, the session token, and the
pending intent. The callback's dispatch at `phantom_callback.html.erb:149`
becomes a step-machine advance rather than a single `signIn` branch.

---

## Per-wallet adapters

All three share **one encryption core**: an x25519 keypair per session,
Diffie-Hellman shared secret, `dapp_encryption_public_key` out,
`<wallet>_encryption_public_key` back, payloads encrypted with nacl.box. Solflare's
documented scheme matches Phantom's architecture almost line for line.

Which means the crypto already in `_phantom_deeplink.html.erb` and
`phantom_callback.html.erb` **is not Phantom-specific** — it is the shared half of
all three protocols. An adapter is mostly a base URL and a method table.

| Wallet | Base URL | connect | signIn | signMessage | signTransaction | signAndSend | browse |
|---|---|---|---|---|---|---|---|
| Phantom | `phantom.app/ul/v1/` | ✅ | ❌ *(undocumented)* | ✅ | ✅ | ⛔ **deprecated** | ✅ *(no `v1`)* |
| Solflare | `solflare.com/ul/v1/` | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ |
| Backpack | `backpack.app/ul/v1/` | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ *(path form contradictory)* |

**No wallet ships a documented `signIn` deeplink.** Phantom's 404s in its docs
and exists only in its official demo app — where the payload is base58
*plaintext*, not ciphertext, and the response key is `address` or `public_key`
(the demo defends both). **The app's current mobile sign-in depends on that
undocumented endpoint.** Retiring that dependency belongs in this epic.

Sources: [Phantom deeplinks](https://phantom.com/learn/blog/the-complete-guide-to-phantom-deeplinks) ·
[Solflare deeplinks](https://docs.solflare.com/solflare/technical/deeplinks) ·
[Solflare encryption](https://docs.solflare.com/solflare/technical/deeplinks/encryption) ·
[Backpack deeplinks](https://docs.backpack.app/)

**Verify during implementation**, do not trust this table alone: exact parameter
names per wallet, and whether Backpack ships `browse`. Vendor deeplink surfaces
change, and this table is a snapshot taken 2026-09-07.

---

## The three-tier mobile strategy

| Tier | Path | Covers | Work |
|---|---|---|---|
| 1 | Already inside a wallet's in-app browser → injected provider | **Every wallet** | None — works today |
| 2 | Redirect adapter (deeplink) | Phantom, Solflare, Backpack | The build |
| 3 | `browse` handoff — "Open in \<Wallet\>", which lands the user in tier 1 | Any wallet with a browse link | Small |

Tier 3 is the safety net. A wallet with no adapter still gets a working path by
being handed into its own browser, where the inline transport already works.

**Interim mitigation, available immediately:** guard `detect()` at the four
unguarded call sites — `_turf_totals_board:1631`, `_world_cup_survivor_board:142`,
`contests/new:424`, `generator:94`, the four that dereference the result without a
null check — and tell mobile users to open the page in their wallet's browser. That is tier 1 by hand, needs no new architecture, and stops the crash
while tier 2 is built.

---

## Scope: which flows

Enumerated from every `connect` / `signTransaction` call site.

### Must work on all platforms

| Flow | Location |
|---|---|
| Contest entry — turf totals | `app/views/contests/_turf_totals_board.html.erb:1631` |
| Contest entry — world cup survivor | `app/views/contests/_world_cup_survivor_board.html.erb:142` |
| Create contest | `app/views/contests/new.html.erb:424` |
| Contest generator | `app/views/contests/generator.html.erb:94` |
| Username rename | `app/views/shared/_alpine_factories.html.erb:787` |
| Wallet export | `app/views/wallet_exports/show.html.erb:132` |
| Sign-in | `app/views/layouts/application.html.erb:244` — *mobile path exists, Phantom only* |

### Desktop-only is a legitimate answer — SHIPPED (`gate-admin-flows-desktop-only`)

An admin signing a 2-of-3 vault operation from a phone is not a use case. These
four declare `inline` only and answer with an honest desktop-required message
under the same capability gate as everything else — which is the point: one
mechanism handles both the supported and the unsupported case.

The gate is `window.walletProvider.requireDesktop()`, in
`app/javascript/wallet_provider.js` — a third member beside `requireProvider`
and `noWalletMessage`, mirrored into the layout's inlined stub. Its sentence
comes from `desktopOnlyMessage()`, so the painted reason and the thrown reason
cannot drift.

| Flow | Gate | Painted ahead of the click? |
|---|---|---|
| Vault init | `app/views/admin/vault_init/show.html.erb` | yes — owns its view |
| Vault state | `app/views/admin/vault_state/show.html.erb` | yes — owns its view |
| 2-of-3 cosign | `app/javascript/cosign.js` | yes — via `admin/pending_transactions` |
| Lock / conclude contest | `app/javascript/lock_contest.js` | **no** — see below |

**It PAINTS, not just throws.** Each of these pages makes the operator do real
work before the signature: vault_state wants a pause reason logged on-chain and
then a `confirm()` naming the network; vault_init wants four pubkeys and a
threshold. Learning "your device cannot do this" after all of that is the moment
somebody starts hunting for a workaround. `shared/_wallet_desktop_only_notice`
renders hidden, reveals itself on a phone, and disables every
`[data-desktop-only-action]` button; the click-time throw stays as the backstop.

**Lock / conclude is the exception, and it is structural.** Its buttons live in
`app/views/contests/**` — the contest header, the show page, the turf-totals
leaderboard — so no single view owns the flow and there is nowhere to paint. Its
whole declaration is the click-time refusal. If those buttons ever consolidate
into one partial, it should adopt the notice too.

**The gate asks about the DEVICE only — do not "tidy" it into
`requireProvider()`.** These callers sign through `window.solana`, while
`detect()` reads `window.phantom.solana`. A legacy Phantom injecting only the
former is a desktop that CAN sign and that a composed gate would refuse, telling
the operator to install an extension they already have.
`e2e/cosign_fresh_transaction.spec.js` stubs exactly that browser and goes red on
the composed version — verified, not asserted. The wallet question stays where it
already was, at each call site's own `isPhantom` check.

Evidence: `test/lib/wallet_desktop_only_js_test.rb` (copy + device rules),
`test/integration/wallet_stub_parity_test.rb` (stub mirrors the module),
`test/views/admin_desktop_only_notice_test.rb` (markup), and
`e2e/admin_desktop_only.spec.js` (the only tier that can see the notice paint,
the buttons disable, and a desktop stay untouched).

`app/javascript/solana_stores.js:232` already guards correctly
(`!provider || !provider.connect`) and degrades cleanly. It needs no change.

---

## Cross-gem sequencing — the real risk

| Repo | Owns | Constraint |
|---|---|---|
| `turf-monster` | Call sites, the blocking SRI-pinned tweetnacl tag | Engine floor `~> 0.72` |
| `solana-studio` | `startPhantomDeepLink`, the wallet picker | Rails::Engine, joins the view lookup path |
| `studio-engine` | **The callback view** — step dispatch at `:149` | Where the resume contract lives |

The callback lives in the engine and the deeplink lives in solana-studio, so any
change to the resume contract must land in **both gems before turf-monster can
use it**, with a floor bump. The Gemfile's floor notes record several rounds of
silent failure from exactly this shape of drift.

**Freeze and version the journal format before anything ships.** A `wallet_dl_v`
field in the journal, checked by the callback, means an old callback meeting a new
journal fails loudly instead of decrypting garbage. That single field is the
cheapest insurance in the design.

---

## Phasing

| Phase | Work | Proves |
|---|---|---|
| **0** *(optional, ~1 day)* | Guard `detect()`; capability-gated messaging; tier-3 handoff copy | Stops the crash today |
| **1** | Encryption core + `walletOps` + all three adapters, wired to **contest entry only** | The transport abstraction, end to end, on the flow that is bleeding |
| **2** | Migrate the remaining five user-facing flows; ~~admin flows get desktop-only messaging~~ (**done** — `gate-admin-flows-desktop-only`) | Mobile parity |
| **3** *(optional)* | Android Mobile Wallet Adapter | Better Android UX — no page destruction |

Phase 1 covering all three wallets was chosen deliberately: they share the
encryption core, so adapters two and three are largely a base URL and a method
table, and it fixes the Solflare/Backpack mobile dead end in the same pass.

Android MWA is intent-based and does **not** destroy the page, so it is a strictly
nicer transport — but it is Android-only and a much heavier dependency. The
universal-link adapters cover iOS and Android on one code path, which is why they
come first.

---

## Open questions

1. Exact per-wallet parameter names — verify against each vendor's live docs at
   implementation time.
2. Does Backpack ship a `browse` method? Not listed on its provider-methods index.
3. ~~Session lifetime per wallet.~~ **Answered:** sessions never expire on any of
   the three. No refresh hop is needed.
4. **Backpack documents no devnet cluster.** Its `cluster` parameter documents
   only mainnet-beta and an Eclipse chain id; devnet and testnet appear nowhere
   in its corpus. turf-monster tests on devnet, so this may block QA of the
   Backpack adapter entirely — resolve before committing to that lane.
5. **Backpack's connect response key is ambiguous.** Its encryption page says
   `wallet_encryption_public_key`; its connect page says `wallet_xxx`, which
   reads as an unresolved placeholder. Needs a device test.
6. Backpack documents **no custom URI scheme** — universal links only. Unlike
   Phantom, there is no scheme fallback.
4. How many real users are affected? Searching LogRocket sessions for
   `provider.connect` gives the distinct-user count, which should size phase 1's
   urgency against the rest of the backlog.
