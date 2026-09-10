# Wallet Adapter Evaluation — Who Owns the Mobile Deeplink Protocol

**Status:** Recommendation awaiting Mr. McRitchie's ratification.
**Written:** 2026-09-10, after the CI stub landed (turf PR 673, merge
`7347c6e0`, on `accepted` 2026-09-09 22:20 MDT).
**Task:** https://mcritchie.studio/tasks/decide-deeplink-protocol-ownership
**Operator decision behind it (2026-09-10):** "Deeplinks: evaluate a maintained
adapter now."
**Companion:** [WALLET_TRANSPORT_ARCHITECTURE.md](WALLET_TRANSPORT_ARCHITECTURE.md)
describes the protocol this page evaluates.

Every external fact below carries a URL and was read on **2026-09-10**. Every
fact about our code carries a `path:line` measured on this branch, or in the
installed gem the lock resolves (solana-studio **0.9.3**, studio-engine
**0.74.7**). Anything not verified is marked **unverified**.

---

## The recommendation

**Keep the protocol. Make it smaller. Re-open the question on the triggers below.**

1. **No maintained library signs a transaction for a Phantom user in iOS
   Safari today.** Mobile Wallet Adapter refuses iOS by design. Anza's adapter
   is dormant and has no iOS path. Reown AppKit's own source code sends Phantom
   and Solflare phone users into the wallet's in-app browser, which is the
   fallback we already ship. Phantom's Connect SDK is a different custody model
   that needs a Phantom Portal app ID.
2. **What still escapes CI is the callback page and OS behaviour, not the
   protocol.** Since the stub landed, a phone found a callback-page gap, and the
   frozen-card trap can only be seen on a phone. Every option that works on iOS
   for our wallets still leaves the browser, so we would own that page under
   any of them.
3. **The one protocol defect that reached a phone is now guarded three ways**:
   the gem refuses to build the URL, the journal carries the value, and the CI
   stub asserts it.

**Decision to ratify:**

- **Do not adopt a replacement.** Keep solana-studio's redirect transport as the
  mobile-browser signing path on iOS and Android.
- **Shrink what we own** (separate tasks, none in this change):
  - Say plainly that this app drives **Phantom's signing dialect only**.
    Solflare and Backpack reach users through the browse handoff, not through
    their signing dialects (see "What we own today").
  - Retire the legacy `phantom_dl_*` sign-in path. It is a second copy of the
    codec.
  - Wire `walletJournal.purge()` into logout **before** taking solana-studio
    0.10.0. That release adds a session record that never expires.
- **Do not adopt MWA on Android yet.** It adds a transport and removes nothing.
  Measure Android's share of mobile entries first; the staged plan below is
  ready if the share is large.
- **Keep the phone session** (`/tasks/verify-wallets-on-a-phone`). It covers the
  classes CI cannot see.

---

## What we own today (measured)

The redirect transport ships in the solana-studio gem. This app wires it up,
and studio-engine owns the page a wallet returns to.

| Piece | Where | Lines |
|---|---|---|
| Codec (x25519 + `nacl.box`), inline base58, per-vendor `PROFILES`, URL builders | solana-studio `app/assets/javascripts/solana_studio/wallet_transport.js` (codec `:235-272`, `PROFILES` `:105-174`, `requireField` `:310-319`) | 399 |
| Provider factory, journal versioning, begin/complete per op | solana-studio `.../redirect_provider.js` (`JOURNAL_VERSION` `:37`, `beginConnect` journal `:194-204`) | 309 |
| Resume journal: `localStorage` key `wallet_dl_journal`, 10-minute expiry, read-and-clear `take()` | solana-studio `.../wallet_journal.js` (`KEY` `:30-31`, `MAX_AGE_MS` `:37`) | 154 |
| Intent registry + step machine | solana-studio `.../wallet_ops.js` (`runInline` `:259`, `runRedirect` `:297`, `signingHop` `:418`, `resume` `:437`) | 566 |
| Legacy Phantom sign-in (undocumented `signIn` deeplink) | solana-studio `app/views/solana_studio/_phantom_deeplink.html.erb` | 179 |
| Callback page: `walletOps` resume dispatch, plus the legacy sign-in branch with its **own** nacl decrypt | studio-engine `app/views/solana_sessions/phantom_callback.html.erb` (resume `:166-172`, legacy `:211`, legacy decrypt `:259-268`) | 406 |
| `window.tmWalletOp`: return address, cluster, handoff watch | `app/views/shared/_wallet_op_runner.html.erb` (`CALLBACK_PATH` `:45`, `tmWalletOp` `:159`) | 209 |
| Intents: entry (with the `redirectLink` resume wrapper at `:128-149`), create + bundle, rename | `app/views/shared/_contest_entry_intent.html.erb`, `_contest_create_intent.html.erb`, `_username_rename_intent.html.erb` | 330 / 201 / 298 |
| Provider registry, inline codec, mobile `detect()` | `app/javascript/wallet_provider.js` (`INLINE_TX_CODEC` `:83`, `detect` `:479`, `requireInlineProvider` `:661`) | 671 |
| Stand-in wallet + its spec | `e2e/stub-wallet.js`, `e2e/stub_wallet_round_trip.spec.js` | 459 / 442 |

**Totals.** The gem's four transport files come to **1,428 lines** in 0.9.3.
Its node test files for them come to 1,834 lines (`wallet_ops_js_test.rb`
1,142, `redirect_provider_js_test.rb` 290, `wallet_transport_js_test.rb` 233,
`second_hop_url_js_test.rb` 169).

**The surface is still growing.** solana-studio **0.10.0**, tagged 2026-09-10
00:28 MDT and not yet in our lock, takes the same four files to **1,959 lines**
(+37%) by adding a persisted wallet session. The gem cut **six releases in about
50 hours** (v0.8.0 at 2026-09-07 22:38 MDT through v0.10.0), and every one that
this app needs costs a floor bump.

**Two of the three vendor dialects never run here.** `detect()` returns
`redirectProvider.forWallet('phantom')` on every phone
(`app/javascript/wallet_provider.js:511`), and its own comment says why. The
wallet picker offers Solflare and Backpack only as a **browse handoff** into
their in-app browsers (`openInWallet`, solana-studio
`app/views/solana_studio/modals/_wallet_connect.html.erb:250-255`). So their
signing profiles are exercised by node tests alone. Backpack also documents no
devnet cluster (`wallet_transport.js:162-166`).

---

## The defect record

Pulled from every board stage on 2026-09-10 (`bin/task list --stage <s> --json`
for all eight stages, 1,981 tasks), filtered on wallet, mobile and
wallet-transport risk tags and on deeplink text, then traced to commits.

| Defect | Record | Caught by |
|---|---|---|
| `provider.connect` on `null` in iPhone Safari. This came **before** the protocol and is the reason it exists. | `/tasks/guard-wallet-detect-mobile`, turf PR 614 | **Real phone** (a production user, via LogRocket) |
| Picker comment said Solflare and Backpack had no deeplink, so phones got a desktop download page | `/tasks/fix-wallet-picker-deeplink-claim`, solana-studio PR 37 | Reading vendor docs |
| `signingHop` preferred wallet broadcast for a co-signed transaction (latent) | `/tasks/intent-declares-sign-only`, solana-studio PR 39; consumer half `1c056cd7` | Building the first consumer |
| Inline path could not carry wire bytes; no post-connect account check | `/tasks/walletops-blocks-inline-unification`, solana-studio PR 41 | Building the first consumer |
| `detect()` never returned a redirect provider, so the board's mobile branch was dead code | `7c113e4a` (PR 632) | Browser tier, during the build |
| Entry intent not registered on the callback page | `eb260fcd` (PR 632), "BLOCKER 1" | Review, lap 1 |
| `requireProvider()` handed a redirect provider to three inline callers | `eb260fcd` (PR 632), "BLOCKER 2" | Review, lap 1 |
| `complete()` called `authedFetch`, which the callback page does not have | `1c056cd7` (PR 632) | Review, lap 2 |
| **Hop 2 carried no `redirect_link`, and an approved entry was lost** | `/tasks/resume-validates-journal-completeness`, solana-studio PR 44 | **Real phone** (QA iPhone, 2026-09-09) |
| Round-trip integration test supplied its own `redirect_link` | `d88601cf` (PR 673) | Building the stub (a test defect) |
| Handoff watchdog armed before `prepare` finished | `/tasks/arm-handoff-watch-later`, turf PR 679 | Review of PR 674 |
| Create and bundle intents said nothing during the cosign leg | same task, defect 2 | Review of PR 674 |
| No celebration and a stale token count after a redirect entry | `/tasks/carry-entry-celebration-across-redirect` | **Real phone** (QA iPhone, **after** the stub landed) |
| Card that cannot be dismissed after an abandoned handoff (bfcache restore) | `/tasks/frozen-wallet-overlay-traps-user` | Review; reproducible only on a phone today |
| Callback page shows one static line for about 18 s, naming Phantom | `/tasks/callback-page-narrates-the-wait` | Review of PR 679; timing from a QA iPhone |
| Stub rejection spec raced a navigation, and its body-text assertion was vacuous | `/tasks/stub-wallet-rejection-race`, turf PR 684 (`fc837382`) | CI (a harness defect) |

**What the record says, in plain terms:**

- **Three defects reached a phone.** One came before the protocol existed. One
  was in the protocol core (`redirect_link`). One was on the callback page
  (the missing celebration).
- **The protocol core escaped to a phone once.** Review, the browser tier and
  the first consumer caught the other core defects before any reached a user.
- **The class that keeps escaping is the callback page and OS behaviour**:
  nothing painted after success, a frozen card after a bfcache restore, a
  silent 18-second wait. A library would not own that page while signing still
  leaves the browser.

**A correction to the task record and to the stub's own header.** The task
record says three defects were "findable ONLY on a real phone". The headers of
`e2e/stub-wallet.js:3-11` and `e2e/stub_wallet_round_trip.spec.js:3-7` name
those three: the unregistered intent, the `detect()`/provider defect, and the
missing `redirect_link`. The commit record places the first two **before PR 632
merged**, found by review (`eb260fcd`) and by the browser tier (`7c113e4a`).
Nothing in the record shows a phone involved. Only `redirect_link` was found on
a phone.

### What the CI stub has caught since it landed

- **Product defects: none.** It landed at `7347c6e0` (2026-09-10 04:20 UTC).
- **Harness defects: one.** Its rejection spec raced a navigation. Fixing it
  showed that the spec's body-text assertion was vacuous, because the callback's
  debug log echoes the wallet's URL params (`fc837382`, PR 684).
- **Before it landed**, the stub reproduced the `redirect_link` defect on
  `accepted` (`3f565729`, 20:14 MDT). The phone had found it first: the task was
  filed at 17:06 MDT. That proves the stub can see this class. It is not an
  independent catch.

### What the stub structurally cannot see

- **iOS WebKit.** `playwright.config.js:106-116` declares two projects, and both
  run `chromium`. "iPhone" in the spec is a user-agent swap
  (`e2e/stub_wallet_round_trip.spec.js:26-31` says so).
- **A bfcache restore.** Playwright launches Chromium with
  `--disable-back-forward-cache` (`node_modules/playwright-core/lib/server/chromium/chromiumSwitches.js:59`,
  playwright-core 1.58.2, the version `package-lock.json` resolves). So the
  frozen-card trap cannot be reproduced in CI.
- **The OS app switch**, iOS opening a universal link in a new tab, and whether
  Phantom accepts our URLs.
- **Solflare and Backpack.** The stub routes `https://phantom.app/**` only
  (`e2e/stub-wallet.js:258`), and its contract table is Phantom's.
- **Callback-page UX, unless a spec asserts it.** The missing celebration was
  visible to Chromium. No spec asserted the card.

---

## Candidates

### Maintenance evidence

From the npm registry (`https://registry.npmjs.org/<package>`) and the GitHub
REST API, both read 2026-09-10.

| Candidate | Latest release | Repository activity |
|---|---|---|
| Solana Mobile Wallet Adapter — `@solana-mobile/wallet-standard-mobile` | 0.6.0, 2026-08-17 (canary 2026-09-09) | `solana-mobile/mobile-wallet-adapter`: 50 commits since 2026-06-10, last 2026-09-09 |
| — `@solana-mobile/wallet-adapter-mobile` | 2.3.0, 2026-08-17 | same repository |
| Anza wallet adapter — `@solana/wallet-adapter-base` / `-react` | 0.9.27 / 0.15.39, both 2025-06-10 | `anza-xyz/wallet-adapter`: 0 commits since 2026-06-10, last 2026-04-01 |
| Phantom Connect — `@phantom/browser-sdk` | 2.0.2, 2026-04-27 | `phantom/phantom-connect-sdk`: 0 commits since 2026-06-10, last 2026-04-28 ("chore: sync from internal"; the public repo looks like a mirror, **unverified**) |
| Reown AppKit — `@reown/appkit`, `@reown/appkit-adapter-solana` | 1.8.23, 2026-07-22 (prereleases 2026-09-09) | `reown-com/appkit`: 26 commits since 2026-06-10, last 2026-09-09 |
| Wallet Standard — `@wallet-standard/core` | 1.1.2, 2026-06-03 | `wallet-standard/wallet-standard`: last commit 2026-06-03 |
| ConnectorKit — `@solana/connector` (Solana Foundation) | 0.2.6, 2026-07-09 | `solana-foundation/connectorkit`: 6 commits since 2026-06-10, last 2026-08-13 |

### Fit

| | iOS Safari signing | Keeps the page alive | Phantom · Solflare · Backpack | Co-signed entry (`ptx_slug`) | Loads in turf |
|---|---|---|---|---|---|
| **Ours** | ✅ Phantom, end to end on a QA iPhone (per `/tasks/carry-entry-celebration-across-redirect`) | ❌ page destroyed per hop | Phantom signs; Solflare and Backpack browse-handoff only | ✅ `signOnly: true` (`_contest_entry_intent.html.erb:68`) | ✅ today |
| **MWA** | ❌ "MWA is not available on any iOS browser" | ✅ by construction: the page holds a WebSocket to the wallet (spec 2.0); not device-verified here | Android: Phantom ✅, Solflare ✅, Backpack not listed | ⚠ sign-only `sign_transactions` is under "Deprecated Methods" in spec 2.0 | ✅ prototype, see below |
| **Anza adapter** | ❌ its mobile path is MWA | Android only, via MWA | injected wallets + MWA | inline path ✅ | ⚠ React-first (`APP.md`) |
| **Phantom Connect** | ⚠ embedded wallets only; existing seed-phrase app wallets are not documented from a mobile browser | ✅ for embedded signing (**unverified** on a device) | Phantom only | ❌ co-signing only through `presignTransaction` on `signAndSendTransaction`, so Phantom broadcasts | needs a Portal app ID and a verified domain; not prototyped |
| **Reown AppKit** | ❌ for Phantom and Solflare: it redirects them to `/ul/browse/` (the in-app browser) | ✅ for WalletConnect wallets | Phantom and Solflare do not speak WalletConnect; Backpack integrated WalletKit on mobile (2024) | ✅ via the injected provider in the in-app browser | ⚠ needs a Reown project ID; `@reown/appkit-cdn` unpacks to 33 MB and pulls wagmi and viem; not prototyped |
| **Wallet Standard** | ❌ nothing is injected in iOS Safari | n/a | whatever is injected | ✅ (we use it already) | ✅ already in `wallet_provider.js` |
| **ConnectorKit** | ❌ MWA (Android) plus WalletConnect wallets such as Trust and Exodus | Android only | not Phantom or Solflare over WalletConnect | inline ✅ | React + headless core; not prototyped |

### What each would own, and what we would still own

- **MWA.** It would own connect and sign on Android Chrome with the page alive,
  with no journal, no callback and no codec of ours. It registers as a Wallet
  Standard wallet, so it could ride our **existing inline transport**
  (`walletOps.runInline`) and `INLINE_TX_CODEC` unchanged (see the staged plan).
  We would still own **all of iOS**: the journal, the callback page, the runner
  and the stub. So on Android it replaces; overall it adds.
  - Its own docs name new friction: browsers' Local Network Access permission
    "breaks MWA wallet connections" without v0.5.0+, which shows an info
    dialog, a browser prompt, and a success dialog once per browser.
- **Anza adapter.** It would own nothing we need. Its app guide says wallets
  implementing MWA or Wallet Standard "will be available automatically", which
  is MWA again. Solana Mobile's own iOS page describes Wallet Adapter as
  deprecated "in favor of the generalized Wallet Standard on the web".
- **Phantom Connect.** It would own wallet custody for **new** users
  (Google or Apple login, embedded wallet). It does not own signing for a
  seed-phrase wallet living in the Phantom app. Its docs say it "converts the
  existing **seedless** wallet". Its npm README (2.0.2) lists a `"deeplink"`
  provider that "redirects users to the Phantom mobile app to complete
  authentication". The docs site's Browser SDK page lists only `injected`,
  `google` and `apple`. The vendor disagrees with itself, so treat this as
  **unverified**. A new embedded wallet would not match the address a user has
  already linked, and this app can link a Solana wallet but not unlink one
  (`app/controllers/accounts_controller.rb:23` lists `link_solana` and only
  `unlink_google`).
- **Reown AppKit.** For our two main wallets it owns nothing new on a phone.
  `packages/controllers/src/utils/MobileWallet.ts` (reown-com/appkit at
  `bee40f6f`, last changed 2026-03-15) says "Phantom doesn't support
  WalletConnect, uses Universal Links". On a phone it sets `window.location.href`
  to `https://phantom.app/ul/browse/<page>`, or to
  `https://solflare.com/ul/v1/browse/<page>`. That is our tier 3. **Adopting it
  would downgrade a Phantom user in iOS Safari** from signing in place to
  reopening the site inside Phantom. It would add real value only for Backpack,
  and only if Backpack's WalletKit works on iOS today (**unverified**).
- **Wallet Standard.** It is discovery for injected wallets, and we already use
  it. Solana Mobile notes that a wallet shipping an iOS **Safari Web Extension**
  would be detected by standard libraries. Phantom's help center lists Chrome
  and Chromium browsers for its extension and does not mention Safari. Whether
  Solflare or Backpack ship one is **unverified**.

Phantom's own end-user help says: "On mobile, connecting only works inside
Phantom's in-app browser. You can't connect from Safari, Chrome, or other mobile
browsers." That is its guidance for the standard connect button. It does not
retire the deeplink protocol: Phantom's docs still publish it, with no
protocol-wide deprecation, and only the `signAndSendTransaction` deeplink is
deprecated. And our own round trip completed on a QA iPhone (per
`/tasks/carry-entry-celebration-across-redirect`).

---

## Security constraints every option must keep

| Constraint | Ours | MWA (Android) | Phantom Connect | AppKit |
|---|---|---|---|---|
| **1. No key-bearing credential in `localStorage`.** The export flow signs a message carrying the token that guards the decrypted-key page (`WalletExportsController.prove_message`, `app/controllers/wallet_exports_controller.rb:86-91`; reasons at `app/views/wallet_exports/show.html.erb:129-176`). | ✅ The journal holds the dapp's ephemeral secret and the unsigned transaction, neither key-bearing (architecture doc §4). Export stays inline. ⚠ **0.10.0 adds a session record with no expiry**, and its own comment says nothing calls `purge()` yet while turf sweeps only `phantom_dl_`. | ✅ The page survives, so nothing needs journalling. This could even let export sign on Android without persisting the challenge. The default authorization cache stores a wallet auth token (location **unverified**). | ⚠ depends on `@phantom/indexed-db-stamper` (npm deps); what it stores is **unverified** | ⚠ WalletConnect keeps session keys client-side (storage **unverified**) |
| **2. Session replay stays suppressed on every page a sensitive hop lands on.** Only `WalletExportsController` suppresses it (`:101`); `session_replay_active?` is otherwise true in production (`app/helpers/application_helper.rb:118-120`). | ✅ for transactions. The callback runs with replay **on**, which is why export must never cross it. | ✅ no landing page | ⚠ its auth redirect lands on a page we choose; the page must suppress replay if it carries anything sensitive | ✅ for WalletConnect; the in-app browser path is our inline path |
| **3. Contest entry keeps its server-held `ptx_slug` model.** The wallet signs only; the server cosigns and broadcasts. | ✅ | ⚠ the library exposes `solana:signTransaction` (0.6.0 `lib/esm/index.js`), but spec 2.0 lists `sign_transactions` as deprecated. Whether Phantom and Solflare keep answering it is **unverified**. | ❌ "Phantom embedded wallets do not accept pre-signed transactions." A second signer must go through `presignTransaction` on `signAndSendTransaction`. The server would sign **before** the user and lose the look at the signed bytes before broadcast. | ✅ for Phantom and Solflare (in-app browser, inline path); **unverified** for Backpack over WalletConnect |

---

## Migration cost

| Consumer piece | Keep ours | Add MWA on Android | Adopt AppKit | Adopt Phantom Connect |
|---|---|---|---|---|
| `tmWalletOp` runner | unchanged | unchanged; MWA arrives as an inline provider | replaced by the AppKit modal | replaced |
| Intents (`prepare` / `complete`) | unchanged | unchanged | unchanged | `complete` rewritten: Phantom broadcasts |
| Resume wrapper (`_contest_entry_intent.html.erb:128-149`) | retire once the Gemfile floor reaches 0.9.3 | stays for iOS | droppable, but only by accepting the iOS downgrade above | stays for iOS |
| Journal + engine callback page | unchanged | stay for iOS | droppable, but only by accepting the iOS downgrade above | stay (auth redirect) |
| `detect()` ordering (`wallet_provider.js:479-514`) | unchanged | must prefer MWA over `forWallet('phantom')` on Android Chrome | replaced | replaced |
| e2e stub | unchanged | a **new** harness: MWA talks over a local WebSocket, which `context.route` cannot intercept (**unverified** how to stub) | new relay stub | new stub |
| Server (`prepare_entry` / `confirm_onchain_entry`) | unchanged | unchanged | unchanged | cosign moves before the user's signature; confirm becomes reconcile-by-signature |
| Vendor accounts | none | none | Reown project ID | Phantom Portal app + verified domain |

**Is a partial adoption honest?** MWA on Android plus ours on iOS is honest
only if it is described as **adding** a transport, not replacing one. It removes
nothing we own, because iOS still needs every piece. It adds a dependency, a
permission prompt, a test harness we do not have, and a sign-only method its own
spec deprecates. It is worth doing only if Android Chrome carries a real share
of mobile entries. **That share is not measured.**

---

## Prototype (scratch only — not in this diff)

**Question:** does `@solana-mobile/wallet-standard-mobile` load in a page with
no bundler, through an importmap as this app pins JS, under this app's
production CSP?

**Method:** a Playwright Chromium page served at a fake origin. It carried the
exact directives from `config/initializers/content_security_policy.rb` as a
header, an importmap pointing at jsdelivr's `+esm` build, and one call to
`registerMwa`, then read the Wallet Standard registry.

| User agent | Loaded | CSP violations | Registered wallets | Module requests |
|---|---|---|---|---|
| Android Chrome | ✅ | 0 | `["Mobile Wallet Adapter"]` | 58 |
| iPhone Safari (UA swap) | ✅ | 0 | `[]` | 58 |

**What it proves:** the library loads and gates itself on the platform, and
our CSP admits it. `script-src` and `connect-src` already allow `https:` and
`wss:` (`content_security_policy.rb:46`, `:48`). 58 module requests is too many
for production, where it would be vendored with `bin/importmap pin --download`
(not tested). **It does not prove** a signing round trip. That needs an Android
device with Phantom or Solflare.

**This app's JS setup, for reference:** importmap-rails with 20 local pins and
no CDN pins (`config/importmap.rb`). web3.js 1.98.4 and tweetnacl load as
SRI-pinned IIFE tags (`app/views/layouts/application.html.erb:73-78`). The
gem's transport files load through sprockets (`:102-105`). There is no bundler:
`package.json` holds Playwright, tweetnacl (dev) and Tailwind only.

---

## What would change this recommendation

Any one of these re-opens the question. Each says where to look.

1. **Phantom gains a mobile-browser signing path that keeps the page alive.**
   That means WalletConnect support, an iOS Safari Web Extension, or Phantom
   Connect covering seed-phrase app wallets with sign-only.
   *Check:* the comment in AppKit's `MobileWallet.ts`; Phantom's help article
   "Connect Phantom to an app or site"; `https://docs.phantom.com/llms.txt`.
2. **MWA ships iOS.** Spec 2.0 says "iOS support is planned for a future version
   of this specification"; Solana Mobile's iOS page explains why it cannot today.
3. **Phantom deprecates the deeplink protocol as a whole.** Today only the
   `signAndSendTransaction` deeplink is deprecated.
4. **Android Chrome carries a material share of mobile entries.** Then run the
   staged plan below. The operator sets the threshold.
5. **The phone session or production finds a protocol-core defect that the stub
   cannot see.** That is the class a library would own. More callback-page
   defects do not count, since we keep that page either way.
6. **The owned surface keeps outgrowing its defect rate.** 0.10.0 alone adds 37%
   to the gem's transport JS.

---

## Staged plan if the answer becomes "adopt" (MWA on Android)

MWA is the only candidate that removes page death for our wallets on any
platform. The plan keeps ours as the fallback at every stage.

| Stage | Work | Exit evidence |
|---|---|---|
| 0 | Measure the Android Chrome share of mobile `prepare_entry` calls from request user agents, for two weeks | A number the operator accepts or rejects |
| 1 | On a desk: vendor the package through the importmap, call `registerMwa` on Android Chrome only, and have `detect()` prefer the MWA wallet over `forWallet('phantom')`. The inline path and `INLINE_TX_CODEC` carry it unchanged. | Unit tests on the `detect()` order; the prototype above re-run against the vendored file |
| 2 | Android device test: a co-signed contest entry through Phantom and through Solflare, with `solana:signTransaction` (sign-only) | The server receives signed bytes and cosigns; the recorded Local Network Access prompts are acceptable |
| 3 | Behind a flag, default on for Android Chrome; the redirect transport stays for iOS and for any MWA failure | Two weeks of entries with no MWA-only defect |
| 4 | Re-run this evaluation's defect table | Fewer Android escapes than the redirect path had |

---

## Unverified — said plainly

- Whether Backpack's WalletConnect integration works on iOS today. The source
  is a Reown blog post of 2024-09-20.
- Whether Solflare or Backpack ship an iOS Safari Web Extension.
- Whether Phantom Connect's `"deeplink"` provider exists as the npm README
  says, since the docs site omits it, and whether it serves seed-phrase wallets.
- Whether Phantom and Solflare still answer MWA's deprecated sign-only method.
- What Phantom Connect, WalletConnect and MWA's authorization cache store
  client-side.
- Android's share of our mobile traffic.
- How MWA's local WebSocket could be stubbed in CI.

---

## Sources (all read 2026-09-10)

- Solana Mobile — MWA for web apps, wallet and browser tables: https://docs.solanamobile.com/get-started/web/apps
- Solana Mobile — wallet signing on iOS: https://docs.solanamobile.com/recipes/mobile-wallet-adapter/wallet-signing-on-ios
- Solana Mobile — Local Network Access permission: https://docs.solanamobile.com/recipes/mobile-wallet-adapter/local-network-access
- Solana Mobile — installing Mobile Wallet Standard: https://docs.solanamobile.com/get-started/web/installation
- MWA 2.0 specification: https://solana-mobile.github.io/mobile-wallet-adapter/spec/spec.html
- Anza wallet adapter, app guide: https://github.com/anza-xyz/wallet-adapter/blob/master/APP.md
- Phantom Connect overview: https://docs.phantom.com/phantom-connect
- Phantom Browser SDK: https://docs.phantom.com/sdks/browser-sdk and https://docs.phantom.com/sdks/browser-sdk/connect
- Phantom FAQ: https://docs.phantom.com/resources/faq
- Phantom docs index: https://docs.phantom.com/llms.txt
- Phantom deeplinks overview: https://docs.phantom.com/phantom-deeplinks/deeplinks-ios-and-android
- Phantom help — connect to an app or site: https://help.phantom.com/hc/en-us/articles/29995498642195-Connect-Phantom-to-an-app-or-site
- Phantom help — browser extension: https://help.phantom.com/hc/en-us/articles/4412436271635-Set-up-the-Phantom-browser-extension
- `@phantom/browser-sdk` 2.0.2 README (npm): https://www.npmjs.com/package/@phantom/browser-sdk
- Reown AppKit mobile wallet handling: https://github.com/reown-com/appkit/blob/bee40f6f844332db3d6dbb5ef9d963a144499afa/packages/controllers/src/utils/MobileWallet.ts
- Reown AppKit Flutter docs (Phantom and Solflare do not use WalletConnect): https://docs.reown.com/appkit/flutter/core/installation
- Reown blog, Backpack and WalletKit (2024-09-20): https://reown.com/blog/reown-formerly-walletconnect-expands-to-solana-following-usdwct-token-announcement
- Solflare integration docs: https://docs.solflare.com/solflare/technical/integrate-solflare
- ConnectorKit: https://github.com/solana-foundation/connectorkit
- npm registry metadata: `https://registry.npmjs.org/<package>` for every package in the maintenance table
