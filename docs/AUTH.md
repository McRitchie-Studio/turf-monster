# Authentication & Account Management

Turf Monster is passwordless. The live sign-in surface is `GET /signin`
(`SessionsController#new`), and legacy `GET /login` / `GET /signup` redirect
there while preserving query params.

## Auth Methods

Users can authenticate through any of these paths:

- **Email magic link** - `POST /magic_link` requests a link, `GET /magic_link/:token` renders a scanner-safe confirmation page, and `POST /magic_link/:token` consumes the token.
- **Google OAuth** - OmniAuth + `GoogleOauthValidator` re-check Google's ID token before linking or creating a user.
- **Solana wallet** - Phantom / Wallet Standard SIWS flow through `SolanaSessionsController`; the server verifies the Ed25519 signature without calling Solana RPC during sign-in.

There is no password login, no password reset, and no `User#authenticate`.
`users.password_digest` remains in the schema only as dormant legacy baggage.

See [SIGNUP_FLOWS.md](SIGNUP_FLOWS.md) for end-to-end flow diagrams.

## Legal-Age Attestation

The underwriting-compliance checkbox is flag-gated by
`AppFlags.age_attestation?` / `ENABLE_AGE_ATTESTATION`.

When the flag is off, each callsite omits the render, client auth models
initialize as already attested, server signup gates pass, and
`age_attested_at` is intentionally not stamped. When the flag is on, brand-new
magic-link, Google, wallet, and fallback `POST /signup` creations must carry the
attestation.

The checkbox is the studio-engine partial
`studio/modals/shared/_age_attestation`, which deliberately does NOT self-gate.
Each callsite gates its own render on `AppFlags.age_attestation?`, and a new
callsite must do the same. A `<template>` body renders server-side whether or
not Alpine mounts it, so an unwrapped render ships the parked checkbox in the
page source of every page that carries the partial.

The three callsites, and how each gates:

| Callsite | Gate |
|---|---|
| `modals/_auth` | `<% if AppFlags.age_attestation? %>` around the render |
| `shared/_auth_card` | `<% if AppFlags.age_attestation? %>` around the render |
| the Connect-Wallet picker | `WalletPickerHelper#wallet_connect_modal_locals` passes the gem picker a `slot:` — or `nil` when the flag is parked |

The picker is solana-studio's (`solana_studio/modals/_wallet_connect`) — adopted
from studio-engine in /tasks/adopt-turf-engine-picker, then moved on to
solana-studio in /tasks/turf-rides-gem-modals — so its attestation arrives as that
partial's `slot` local rather than an inline render.

## User Model Auth Design

Current authentication identity lives directly on `users`:

```ruby
has_one_attached :avatar
validates :email, uniqueness: true, allow_nil: true
validates :web2_solana_address, uniqueness: true, allow_nil: true
validates :web3_solana_address, uniqueness: true, allow_nil: true
validates :username, length: { in: 3..30 },
                     format: { with: /\A[a-zA-Z0-9_-]+\z/ },
                     uniqueness: { case_sensitive: false },
                     allow_nil: true
validate :has_authentication_method
```

Important invariants:

- `email` is nullable; wallet-only users may not have one.
- Email format uses `User.valid_email?`, shared by model validation and magic-link request handling.
- `has_authentication_method` requires at least one of email, Google `(provider, uid)`, or Solana wallet identity.
- `display_name` falls back through username, name, email prefix, truncated wallet address, then `"anon"`.
- `profile_complete?` is `username.present?`; usernames are auto-generated on create, so normal signups are immediately complete.
- `before_create :set_initial_session_token` writes the OPSEC-045 session-binding token.
- `after_create :generate_managed_wallet!` creates a server-managed Solana wallet for non-admin users — **but mints nothing while web3-only onboarding is on, which is the default** (see [Web3-only onboarding](#web3-only-onboarding)). A new account therefore has NO wallet until it links Phantom, unless `ENABLE_WEB3_ONLY_ONBOARDING=false` restores custodial minting.
- `after_commit :enqueue_onchain_account_setup` creates the on-chain username PDA asynchronously.

## Email Magic Links

Routes:

- `POST /magic_link` - request a create-or-login link for an email.
- `GET /magic_link/:token` - inert confirmation page. It does not consume the token, so link scanners cannot burn the login.
- `POST /magic_link/:token` - authoritative consume; signs in an existing user or creates a new one.

The consume step proves email ownership. Existing users with blank
`email_verified_at` are stamped verified on consume. New users are built from
the email in the token, pass through `Studio.configure_new_user`, get the normal
managed-wallet callbacks, then receive a session through `set_app_session`.

Magic-link session setup hard-resets any prior browser session first. This
prevents a previous Phantom/web3 session from leaking `session[:onchain]`,
nonces, return targets, or client wallet state into the new web2 email session.

## Google OAuth

Routes:

- `POST /auth/google_oauth2` - normal OmniAuth request phase.
- `GET /auth/google_oauth2/callback` - callback handled by `OmniauthCallbacksController#create`.
- `GET /auth/google_popup` - popup-mode entrypoint used by the in-contest auth
  modal. It renders an auto-submitting POST form to the OmniAuth request phase.

The callback re-validates Google's ID token with `GoogleOauthValidator` before
trusting `auth.info.email`. `User.from_omniauth(auth, email_verified: true)`
then:

- returns an already-linked `(provider, uid)` user,
- links an existing email user only if that user had already verified email
  ownership, or
- creates a new verified Google user.

If Google collides with a wallet account that has not verified email ownership,
the controller stores a short-lived pending Google identity and asks the user to
prove wallet ownership before linking.

## Solana Wallet Auth

Routes:

- `GET /auth/solana/nonce`
- `POST /auth/solana/verify`
- `GET /auth/phantom/callback` for mobile deep links
- `GET /login/wallet` for the Google-collided-with-wallet recovery path

All four are drawn by **this app**, not the engine: `config/initializers/studio.rb`
sets `Studio.draw_auth_routes = false`. The phantom callback in particular MUST
stay declared before `Studio.routes`, which draws the OmniAuth wildcard
`auth/:provider/callback` unconditionally and would otherwise recognise
`/auth/phantom/callback` as `omniauth_callbacks#create` with provider `phantom`.

The mobile deep link itself is **solana-studio's**: `adopt-engine-phantom-deeplink`
took it off this app, and `turf-rides-gem-modals` moved it on to the gem, so
`solana_studio/_phantom_deeplink` publishes `window.startPhantomDeepLink`.
**studio-engine's** `solana_sessions/phantom_callback`, which never moved,
completes the return leg. Turf renders the deep link once from `shared/_alpine_factories` (one
callsite, both layouts that mount the wallet picker), keeps its own blocking
tweetnacl tag rather than the gem's async `solana_studio/_deeplink_assets`, and
opts the callback's debug sink back on with
`Studio.wallet_debug_sink = -> { !AppFlags.live_production? }`.

**One layout loads that tag, unconditionally, and that is the whole guarantee
now.** `layouts/application` loads tweetnacl on every page. Rendering the deep
link is unconditional too, so every page publishes `window.startPhantomDeepLink`
— and the gem picker paints its mobile Phantom row on that global merely
EXISTING. A page that publishes the global WITHOUT the tag paints a row whose tap
throws `nacl is not defined` synchronously, before the fetch, where nothing
catches it.

That used to be reachable. `layouts/modal_preview` gated the tag per modal id,
because loading web3.js and tweetnacl in every gallery iframe stalled the page,
and the gate was narrower than the set of cards that could put a caller on
screen — `/tasks/preview-gallery-deeplink-dead`. `phantom_deeplink_adoption_test`
carried a derivation for it: the deep-link callers plus anything reaching one
through `swap`/`open` hops, failing closed on a target it could not read.
`/tasks/retire-the-preview-harness` deleted that layout on 2026-09-09, which
deleted the gate and with it the derivation — there is nothing left for a gate to
be narrower than. What the test asserts instead is that the surviving tag is
BLOCKING and that it reaches a RENDERED page, not merely that it appears in the
layout source. A SECOND layout rendering `shared/_alpine_factories` would owe
tweetnacl too, and nothing asserts that; add coverage with the layout.

`Solana::SessionAuth#verify_solana_signature!` enforces:

- a server-generated nonce with a five-minute freshness window,
- delete-before-verify replay protection,
- host binding through the SIWS message, and
- optional session/user binding when linking a wallet to an existing account.

Successful wallet sign-in sets the normal app session and then marks
`session[:onchain] = true`. That flag means the current browser session proved
fresh wallet ownership and may sign on-chain actions. It is distinct from the
account-level `web3_solana_address`, because an account can have a Phantom
wallet linked but currently be signed in via magic link or Google.

Signup itself does not touch Solana RPC. New wallet users get a Rails row and
managed wallet immediately; on-chain `UserAccount` creation is async and
idempotent.

### Wallet account changes

A live web3 session watches the authenticated wallet brand's `accountChanged`
event in `app/javascript/solana_stores.js`. The server renders the normalized
brand as `data-wallet-provider`, so a Phantom session binds Phantom's Wallet
Standard adapter even when a generic `detect()` call sees another injected
interface first. The watcher retries provider discovery briefly and upgrades
when Wallet Standard registers late.

Changing accounts does not log the player out. Phantom can emit a temporary
`null` account while it switches, and the watcher deliberately ignores that
provider transition because it does not invalidate the signed Rails session.

Chrome may mark the page hidden while Phantom's side panel has focus, so a
concrete account event is queued even in that state. When Turf Monster regains
focus, the watcher also reads the provider's current public key again; this
recovers cleanly if the extension missed or delayed its change event.

Once the provider reports a concrete address that differs from the session's
address, Turf Monster opens the blocking `wallet-changed` modal. Escape,
backdrop clicks, and a secondary close action cannot dismiss it. The player has
two safe ways forward:

- **Start New Session** signs the ordinary SIWS message and posts it to
  `POST /auth/solana/verify`; success replaces the app session with the selected
  wallet's existing or newly created account.
- Switching the provider back to the session's original address closes the
  modal without changing the app session.

The modal stays retryable when the player cancels Phantom's signature request
or verification fails. It never routes through `/logout` or `/signin` as a
wallet-change fallback.

## Reporting client-side wallet failures

`POST /auth/solana/report_failure` → `SolanaSessionsController#report_failure`.

Wallet sign-in fails **entirely in the browser**. `window.solanaConnectAndVerify`
throws, the modal catches it, `parseSolanaError` maps it, and an `x-text`
paragraph paints it. Nothing reached the server, so `error_logs` never held one
— the only user-facing failure class in the app that was invisible to support.
On **2026-09-06** a player whose Phantom held no keypair was told to check their
USDC balance seven times in one production session before an operator noticed by
hand. This endpoint is the counterpart to the backend discipline's "every
workflow rescues into an ErrorLog" for the client half.

**The pieces:**

| Piece | Where |
|---|---|
| `window.reportWalletFailure(stage, provider, raw, mapped)` | `app/javascript/solana_errors.js` (beside `parseSolanaError`) |
| Endpoint | `SolanaSessionsController#report_failure` |
| Sanitiser + PII rule | `Solana::ClientFailureReport` |
| Row class | `Solana::ClientWalletFailure` |
| Throttle | `solana_report_failure/ip`, 20 / min (`docs/RATE_LIMITING.md`) |

**Both message halves are sent.** `mapped` is what the user read; `raw` is what
the wallet said. A mis-mapping is invisible in the mapped half alone — the
2026-09-06 incident *was* a correct mapper meeting a wallet string it had never
seen.

**It fails open.** The endpoint answers `204` whether it recorded anything or
not, swallows every fault into the Rails log, and is never awaited on the
client. A reporting failure must never surface to the user, block sign-in, or
change what they see. Proven directly rather than by inspection, by TWO specs in
`e2e/wallet_failure_report.spec.js` — and it takes both. The 500 spec proves the
screen is byte-identical when the endpoint refuses; it does **not** prove the
reporter's `.catch()` runs, because `fetch` RESOLVES on a 500 (an HTTP error is a
successful round trip) so nothing ever enters that handler. Deleting the
`.catch()` outright left every other spec in the file green, measured 2026-09-07.
The **dead-network** spec (`route.abort`) is the one that proves it: only a
transport failure rejects the promise, and an unhandled rejection is exactly the
shape a broken fail-open takes here.

**What a row targets.** The **User** when one is signed in (a wallet *link* or a
step-up); **nothing** for a guest sign-in, which has no user by definition —
those are found by class and stage. Worth stating because this app's other
on-chain rows target the **Entry**, so an operator searching `error_logs` by
user comes back empty and reads it as "nothing was logged".

**The PII rule** is the house one, already settled for this domain in
`app/javascript/debug_logger.js`, and is enforced in two layers:

1. **By key — and it is a PAIR, not the permit list alone.**
   `client_failure_params` permits exactly `provider`, `stage`, `raw_message`,
   `mapped_message`, and `ClientFailureReport.from_params` reads exactly those
   four **by name**. Measured 2026-09-07 by mutation: widening the permit list
   to allow `:signature`, `:nonce` and `:message` changed *nothing* and left the
   suite green — the reader never looks at the rest of the hash. So the **reader**
   is what makes a credential unstorable; the permit list is the outer layer that
   keeps it out of the params object and anything that iterates it. The two are
   asserted as ONE set in
   `test/controllers/wallet_failure_reporter_wiring_test.rb`, so neither can be
   widened alone.
2. **By value** — `Solana::ClientFailureReport.scrub` redacts a labelled
   `Nonce: …`, any base58 run of 64+ characters (an ed25519 signature), any hex
   run of 32+ characters (`SecureRandom.hex(16)` is exactly 32), and any RPC
   api-key (delegated to `Solana::Config.redact_message`). Layer 1 cannot see
   inside `raw_message`, and this app hands the wallet a string containing its
   own nonce to sign — so a wallet quoting that message back is a live path for
   a credential to arrive under a permitted key.

A **pubkey is kept, deliberately**: it is public (already on
`<body data-wallet-address>`) and it is the only handle a guest row has. The
signature rule starts at 64 characters precisely so a 44-character pubkey passes
through it.

### ⚠️ All five call sites are wired

Three **render surfaces** catch these rejections, and two of the three live in
the **solana-studio gem** — wired there since **0.7.0**; this app locks 0.9.0.
The other two sites are not surfaces at all — they are the two guards
inside `solanaConnectAndVerify` that REPLACE a wallet's message with one of
ours, and each reports before it destroys the evidence:

| Stage | Where | Status |
|---|---|---|
| `wallet_setup_connect` | `app/views/modals/_wallet_setup.html.erb` | **wired** |
| `connect_verify_fallback` | `app/views/layouts/application.html.erb`, `solanaConnectAndVerify` — `connect()` never answered | **wired** |
| `connect_verify_signature` | `app/views/layouts/application.html.erb`, `solanaConnectAndVerify` — connected, then `signMessage` refused | **wired** |
| `wallet_connect` | solana-studio `solana_studio/modals/_wallet_connect.html.erb` | **wired** — in the gem since 0.7.0 |
| `web3_step_up` | solana-studio `solana_studio/modals/_web3_step_up.html.erb` | **wired** — in the gem since 0.7.0 |

**Nothing in this app checks the gem's two, by choice.** The wiring test below
deliberately does not read the gem's source, and the Gemfile floor is `~> 0.6`,
so those two rows are maintained by hand. They read **not wired** from the day
0.7.0 landed until 2026-09-09 — an operator filtering `error_logs` by
`wallet_connect` was told, by this table, that the stage could hold nothing.
Re-read the gem before trusting the column — `grep reportWalletFailure "$(bundle
show solana-studio)"/app/views/solana_studio/modals/_wallet_connect.html.erb`.
The version above is the EARLIEST tag containing the commit that wired them
(`06bda3b`), not a tag that happens to carry it; and the floor `~> 0.6` still
admits 0.6.x, where both rows are false.

The two layout stages are not a substitute for the surfaces and the surfaces are
not a substitute for them. Each fires for exactly one thing — a failure whose
message the layout is about to REPLACE with a sentence of its own — and the
surfaces still report everything that reaches them intact. **They are two stages
rather than one because they are two diagnoses**, and an operator answers them
differently: `connect_verify_fallback` means the wallet holds no keypair, and
`connect_verify_signature` means it holds one and would not sign. Collapsing them
would put the app's two most confusable wallet failures behind a single filter.

Each substituted error is tagged `walletFailureReported`, and
`_wallet_setup.html.erb` skips a tagged error, so one failure produces one row
rather than two. **Both gem call sites carry that same guard**, in the same
line, so the gem release added no second row carrying our sentence in both
halves. Any FUTURE substituting guard added to `solanaConnectAndVerify` owes all
three things: its own stage, a report made before the substitution, and the tag.
The `connect_verify_signature` guard was added without them on 2026-09-07 (#587)
and silently reopened the byte-identical row this endpoint exists to prevent,
which is why the rule is written down here rather than left to be re-derived.

The reporter deliberately lives **here, not in the gem**. The gem's partials
already call the host-provided `window.parseSolanaError` behind a `typeof`
guard, so `window.reportWalletFailure` follows a contract that already exists:
each gem call site becomes one guarded line, with no gem-side reporter and no
new host dependency. An app consuming solana-studio without it degrades to
silence, exactly as it already does for the mapper.

`test/controllers/wallet_failure_reporter_wiring_test.rb` holds this ledger as
an executable accounting, so a stage cannot be added or dropped without the
table above being wrong out loud. It deliberately does **not** assert against
the gem's source — a consumer test that reddens when the producer ships would
red-seal the gem's own release.

### Four limits worth knowing before reading a row

- **Three branches replace the message before any surface sees it — the two
  WALLET ones report it first, so `raw` is still the wallet's.** On the `connect`
  + `signMessage` fallback path, `solanaConnectAndVerify` REPLACES the wallet's
  message before rethrowing. By the time any surface catches, the original
  Phantom string is gone, so what the USER reads is always our sentence. **What
  `error_logs` holds is not.** Since 2026-09-07
  (`/tasks/raw-message-is-ours`) each substituting WALLET guard reports from
  INSIDE `solanaConnectAndVerify`, at the last point the wallet's own words
  exist, and those two guards report on stages of their own:

  | Substituted failure | Stage | The sentence the user reads |
  |---|---|---|
  | A `connect()` that NEVER ANSWERED (2026-09-06) | `connect_verify_fallback` | "Finish setting up your wallet in … — create or import one, then try again." |
  | Connected, then could not sign — `connect()` returned a public key and `signMessage` rejected (2026-09-07) | `connect_verify_signature` | "Your wallet connected but could not sign you in. Signing in moves no funds — try again." |
  | `/auth/solana/nonce` answered with a body we could not read (2026-09-08) | none, deliberately | "Our server could not start sign-in — the problem is on our side, not your wallet. Please try again in a moment." |

  **The third one reports nothing, and that is the rule below applied, not an
  omission.** It is a fault of OURS: the 500 that produced the unreadable body
  is already in the server's own log with its exception and backtrace, so the
  browser has nothing to add — and the POST would go to the server that just
  failed. The string it replaces is V8's complaint about our error page, never a
  wallet's words, so no diagnosis dies with it. The substituted error carries
  `walletFailureReported` so no SURFACE files it either; without that tag the
  wallet-setup modal would record a row holding our sentence in both halves —
  the `raw == mapped` anomaly named in the triage table below.

  The second substitution exists because rethrowing that failure UNTOUCHED was
  not safe. Phantom's generic "Unexpected error" is the string this path carries
  most often, and `parseSolanaError`'s generic branch rewrites it into "Wallet
  couldn't process the transaction. Check wallet connection and USDC balance." —
  balance advice for a signed-out user who attempted no transaction, which is the
  very sentence the 2026-09-06 fix existed to remove.

  **This page said the opposite until 2026-09-07, and the correction is worth
  stating plainly.** The report used to be made only at a render SURFACE, which
  is downstream of both substitutions, so `raw_message` and `mapped_message`
  arrived BYTE-IDENTICAL — both of them our sentence — for the entire MALFUNCTION
  class this endpoint was built for. A decline (`code 4001`) was the only failure
  that carried a genuine wallet string. For the 2026-09-06 incident itself, the
  raw half said nothing. Reporting upstream of each substitution is what fixed
  that: a row now reads `raw_message: "Unexpected error"` beside
  `mapped_message: "Finish setting up your wallet in Phantom …"`, and a
  mis-mapping is visible again. `mapped` is what the user actually read, which
  rests on `parseSolanaError` passing both substituted sentences through
  untouched — pinned in `test/views/wallet_connect_error_copy_test.rb`.

  Three things rethrow the ORIGINAL untouched. No substitution happens, nothing
  reports from the layout, and the surface reports them intact:

  | Failure | Why it is not a missing wallet |
  |---|---|
  | A decline (`code 4001`, "user rejected/declined") | The human said no |
  | `/auth/solana/nonce` failing to REACH us — the request never arrived, and the rejection still says `Failed to fetch` (tagged `nonceFetchFailed`) | The network, not the wallet — and it leaves no server-side trace, so it stays reportable |
  | The Wallet Standard rejection tagged `walletAnswered` — "No account authorized", an empty accounts array: a dismissed account-selection sheet | The wallet answered and authorized nothing |

  **The adapter tags a SECOND rejection, and it never arrives.**
  `wallet_provider.js` also tags "Wallet not connected", raised when `signMessage`
  is called with no account. `solanaConnectAndVerify` calls `signMessage` only
  after `connect()` has answered — and the `connected` guard rethrows ABOVE the
  `walletAnswered` one, so that string is always substituted as
  `connect_verify_signature`, with the wallet's words kept in `raw`. No operator
  can read it. This table listed it anyway until 2026-09-09, which is what a
  triage table written from the code's SHAPE rather than its BEHAVIOUR looks
  like: it sent a reader after a cause the app cannot produce. Swap those two
  guards and the string becomes reachable again —
  `test/docs/auth_failure_mode_reachability_test.rb` runs the real helper and
  reddens in either direction, naming the row that has to change.

  **Triage by the STAGE, then read both halves.** The stage says which diagnosis
  fired; `mapped` is what the user read; `raw` is what the wallet said. Four
  readings and what they mean:

  | What you see | What it means |
  |---|---|
  | `raw: "Unexpected error"` on `connect_verify_fallback` or `connect_verify_signature` | **Normal, and the fix working.** A substitution fired and the wallet's own generic string was captured before it was replaced. The stage tells you which of the two diagnoses the user was given. |
  | `raw` == `mapped` on either of those two stages | **An anomaly worth chasing.** It means the row came from a surface downstream of the substitution — the layout's report or its `walletFailureReported` tag has regressed — which is exactly the defect fixed on 2026-09-07. |
  | `mapped: "Signature rejected"` beside any `raw` at all | **A decline, whatever the wallet called it.** All three surfaces read `code === 4001` BEFORE the mapper, so the mapped half never depends on the raw half here. A frightening `raw` on this reading is a wallet's wording, not a second failure. |
  | `raw: "Unexpected token '<' …"` | **A REGRESSION, on every stage.** Both legs that could produce this reading are now substituted at the point the failure is identified — the nonce fetch on 2026-09-08, the verify POST on 2026-09-09 — so an unreadable HTML body is named as our server's fault before any surface maps it. A row still carrying this raw string means a guard has been reverted, hoisted, or gated on `r.ok`; the two copy tests named below redden on all three. On `connect_verify_fallback` or `connect_verify_signature` it was always a regression, because neither guard can see a nonce or a verify rejection. (Chrome's wording. Firefox and Safari phrase the same rejection differently, miss the mapper's branch, and hand the user the raw parser noise instead.) |

  **The nonce exposure, closed on 2026-09-08** (`/tasks/nonce-failure-reads-as-balance`).
  This page carried it as a known, deliberately-unfixed hole from 2026-09-07: a
  nonce fetch that fails with an HTML body — see **What actually sends HTML**
  below — makes `r.json()` reject with "Unexpected token '<' … is not valid
  JSON", which matches the mapper's SAME `/^unexpected/i` branch, so the
  commonest server-failure shape reached the user as the transaction sentence. An outage of
  ours, read back to a paying user as their wallet being short of USDC.

  It is now substituted where the failure is identified — inside `r.json()`,
  not at the `nonceFetchFailed` guard, and the difference matters twice:

  - **A guard-local fix would have missed the commonest wallet.** The `signIn`
    branch awaits the nonce ABOVE its `try`, because the nonce is an INPUT to
    `signIn()`, so its rejection is caught by nothing in
    `solanaConnectAndVerify` and lands on the surface intact. Phantom supports
    `signIn`. Measured on both paths, 2026-09-08.
  - **An offline user must not be told it was us.** Inside the single `.catch`,
    a `TypeError: Failed to fetch` and an unreadable 500 body are the same
    rejection; inside `r.json()` they are already separated by which step threw.
    So a request that never reached us keeps its own words and stays reportable.

  The mapper is untouched: its transaction wording still belongs to the entry
  and transaction paths that own it. `test/views/nonce_server_failure_copy_test.rb`
  drives the RENDERED helper against a real 500 with an HTML body and asserts the
  decoded sentence on both paths, and runs the literal past every regex the mapper
  tests a message against.

  **The verify exposure, closed on 2026-09-09**
  (`/tasks/verify-leg-repeats-nonce-bug`). This page carried the same hole one
  fetch later as a known, deliberately-unfixed defect: `solanaConnectAndVerify`
  ended by POSTing to `/auth/solana/verify` (or `/account/link_solana`) and
  calling `.json()` on the answer, outside BOTH `try` blocks and with none of the
  three things the nonce leg gained. A 500 resolves the fetch, `.json()` rejects,
  and the same `/^unexpected/i` branch produced the balance sentence.

  It was WORSE than the nonce case, and that is why it was P1: the nonce fetch
  happens BEFORE the user signs, this one AFTER the signature succeeded. A user
  approved a wallet prompt, our server faulted, and we told them to check their
  USDC balance — on a real-money product, at the moment they had most reason to
  believe something had been taken.

  It is now substituted inside `verifyResponse.json()`, and the site was chosen
  by the same analysis the nonce leg used, with one result that differs:

  - **One site covers both wallet paths, and here that is free.** The `signIn`
    branch and the `connect` + `signMessage` fallback both fall THROUGH to this
    single fetch; neither wraps it. So unlike the nonce leg — where a
    guard-local fix would have missed every `signIn`-capable wallet, Phantom
    included — no second substitution is needed. Both paths are driven, and
    since 2026-09-09 the drive is **verified to be two paths**: the copy test's
    wallet mock is strict (a `signIn`-capable wallet refuses `connect`, and one
    without `signIn` refuses `signIn`) and every drive records which wallet
    methods it reached. Before that, forcing `useSignIn` either way left the
    file green, so "both paths" was a comment rather than a guarantee.
  - **`r.ok` is NOT the fix, and gating on it would be a new defect.** This page
    used to note that "nothing checks `r.ok`" as though the check were the
    remedy. `SolanaSessionsController#verify` answers **401** (expired nonce, bad
    signature) and **422** (age attestation) with a JSON body the user MUST read,
    and the modal paints `result.error` from it. A throw gated on `!r.ok` would
    replace three precise, actionable sentences with one generic one — the same
    confidently-wrong diagnosis, pointed at a new party. Only an UNREADABLE body
    is unambiguously ours, and `.json()` rejecting is exactly that signal.
  - **An offline user must not be told it was us.** Wrapping the fetch itself
    makes `TypeError: Failed to fetch` and an unreadable 500 body the same
    rejection. Inside `.json()` they are already separated by which step threw,
    so a request that never reached us keeps its own words and stays reportable.

  - **The verify POST sends no `Accept` header, and that is load-bearing.**
    Measured 2026-09-09 against `ActionDispatch::PublicExceptions`: with no
    `Accept` (or `*/*`, or `text/html`) a 500 comes back as the rendered error
    PAGE — the body `.json()` rejects on; with `Accept: application/json` the
    same 500 comes back as `{"status":500,"error":"Internal Server Error"}`,
    which **parses**. Adding that header is a one-line tidy-up two sibling call
    sites in the layout already make, and it would silently DISARM this guard:
    `.json()` would resolve, the substitution would never run, and a user who
    had already signed would read a bare "Internal Server Error" instead of
    being told their signature moved no funds. The copy test's fake server now
    answers by `Accept` the way Rails does, so the header cannot be added
    without reddening. Adding it deliberately means re-aiming the guard in the
    same diff — and a JSON error body has to be told apart by STATUS, which the
    `r.ok` bullet above explains this endpoint cannot do naively.

  **What actually sends HTML — not "any unhandled exception".** This page and
  both copy tests carried that sentence until 2026-09-09 and it is FALSE on the
  verify leg: `SolanaSessionsController#verify` and `AccountsController#link_solana`
  each END in a generic `rescue StandardError` rendering **JSON 422**, which
  parses. Three things do send HTML, and **two arrive at status 200**:

  | Producer | What the browser gets |
  |---|---|
  | The engine catch-all — `Studio::ErrorHandling`'s `rescue_from StandardError` claims whatever an action's own rescues do not: a raise in a `before_action`, or in `#nonce`, which has no local rescue | `handle_unexpected_error` → `respond_to`; this fetch sends no `Accept`, so `format.html` → **302 to root**, followed by `fetch` to HTML at **status 200** |
  | OPSEC-045 forced logout (`ApplicationController#verify_session_token`) | `format.html` → **302 to /signin**, followed to HTML at **status 200**. Measured end to end 2026-09-09 |
  | A fault outside `rescue_from`'s reach — middleware, routing | `ActionDispatch::PublicExceptions` → the rendered **500** page |

  `r.ok` is TRUE on the first two, which is the whole argument for substituting
  inside `.json()`: an `!r.ok` gate would not fire at all on the two shapes this
  app actually produces most.

  The substituted error carries `walletFailureReported`, for the reason the nonce
  leg gives: the 500 is already in our own log with its backtrace, and the report
  POST would go to the very server that just failed.
  `test/views/verify_server_failure_copy_test.rb` drives the RENDERED helper
  against a real 500 with an HTML body on both paths and asserts the decoded
  sentence, pins a 401-with-JSON still reaching the user verbatim, and runs the
  literal past every regex the mapper tests a message against.
  `test/docs/auth_failure_mode_reachability_test.rb` now guards the CLOSED state
  through its derived path, so this section and the behaviour cannot drift apart.

  **The cause the substitution costs, bought back on the OPSEC-045 path**
  (`/tasks/verify-guard-leaves-four-holes`, 2026-09-09). The guard is right to
  replace an unreadable body with a sentence the user can act on, but the
  replacement means the surface can no longer say WHY. For the commonest
  status-200 producer in the table above that is now answered server-side:
  `ApplicationController#verify_session_token` files an `ErrorLog` under
  `SessionTokenMismatch` before it clears the session, targeted at the user it
  logged out. So a support report of "it said your server could not finish
  sign-in" is a query — `ErrorLog.where("inspect LIKE '%SessionTokenMismatch%'")`
  — rather than a guess. Before this the forced logout emitted a
  `Rails.logger.info` line and nothing else, which made it the one user-facing
  event in this app that left no row.

  Two properties of that record are deliberate and tested
  (`test/controllers/session_token_mismatch_trace_test.rb`): **neither session
  token is written down** — both are credentials, so the row says only whether
  the cookie carried one (`present but stale` vs `absent`, which distinguishes a
  rotation from a session predating the binding) — and the recorder is
  **fail-open**, swallowing its own faults into the Rails log, because a forced
  logout is a security act and a logger that can veto what it observes is worse
  than no logger.

- **The report is best-effort by design.** It is dropped on a throttle, a
  closed tab that beats `keepalive`, or a blocked request. `error_logs` is a
  triage surface here, never a count.
- **A server REJECTION is not reported from here, on purpose.** When
  `/auth/solana/verify` or `/account/link_solana` answers `{ success: false }`
  — an expired nonce, a bad signature, a failed age attestation — the modal
  paints `result.error` and reports **nothing**. That is deliberate, and the
  reason is the same one that shapes everything above: this endpoint exists for
  failures that leave **no server-side trace at all**, because they happen
  entirely in the browser. A `{ success: false }` already reached the server;
  the server composed that sentence and answered `401`/`422` with it. Reporting
  it back would record OUR words as both halves — the byte-identical row the
  2026-09-07 fix removes — while adding nothing an operator could not read
  server-side. If those rejections should reach `error_logs`, the place to log
  them is `SolanaSessionsController#verify`'s own `rescue` clauses, where the
  cause is in hand.

  **And one of those two rescues writes no `ErrorLog` row — check the LINE
  NUMBERS, not the rescue.** `rescue_and_log` persists a row and then RE-RAISES
  by contract, so anything raised INSIDE its block is already logged by the time
  `#verify`'s rescues see it. But `verify_solana_signature!` is called at
  **:26** and that block does not open until **:59**, so a
  `Solana::AuthVerifier::VerificationError` — an expired nonce, a bad signature,
  a rewritten domain — is raised 33 lines ABOVE the block, never passes through
  the logger, and answers `401` with no row behind it. The `rescue StandardError`
  beside it is the opposite case: it catches the re-raise, and that one IS
  logged. Spelled out because the two rescues sit on adjacent lines and read as
  one behaviour; they are not, and this was misread once on 2026-09-07.
- **CSRF is required, and no automated tier proves it.** Measured against a live
  dev stack (2026-09-07): a tokenless POST is answered **422** and writes no
  report row; `X-CSRF-Token: <token>` is answered **204** and writes one. The
  test env sets `allow_forgery_protection = false` — and Playwright drives a
  test-env server, which is also why `e2e/phantom-mock.js` has to inject a fake
  csrf meta tag — so *every* automated assertion about this endpoint is made
  with CSRF off. What is pinned instead is that the reporter uses the identical
  meta-tag + header plumbing as `solanaConnectAndVerify`'s POST to
  `/auth/solana/verify`, which production exercises on every wallet sign-in
  (`test/controllers/wallet_failure_reporter_wiring_test.rb`). A rename on
  either side refuses every report **silently**.

## Web3-only onboarding

`AppFlags.web3_only_onboarding?` is a **kill-switch: ON by default** since
2026-08-15, off only when `ENABLE_WEB3_ONLY_ONBOARDING` is set to the literal
`"false"`. Email/Google signup is therefore **web3-only**: no custodial web2
wallet is minted, and auth success sends the user to the wallet-setup modal to
link Phantom instead. Operator call for NFL 2026 — supporting web2 players
carries a legal cost Turf can't absorb this season. Reversing it is one env
change, no deploy.

It was an opt-in (default OFF) through the build-out, and stayed unset on
`turf-monster-mainnet` and `turf-monster-qa` — so the wallet step was written,
wired and dark, and a new player fell through the chain to the web2 Buy an Entry
Token modal. Flipping the default is what closed that gap.

**Knock-on for anything that spends:** a fresh account has no wallet, so
`User#solana_connected?` is false and every entry-token rail refuses it
(`TokensController#stripe_checkout`, `#coinflow_order`) — a token must be minted
somewhere. Surfaces that offer a purchase to a signed-in user should branch on
`walletHasAddress` in the session payload, which IS `solana_connected?`. Do not
branch on `mode`: a wallet-less account reads `"web2"`.

| Piece | Where |
|-------|-------|
| The flag | `AppFlags.web3_only_onboarding?` |
| Wallet minting skipped | `User#generate_managed_wallet!` early-returns |
| Who gets prompted | `WalletSetupPolicy` — one policy (Phantom → no wallet → free entry → USDC), both auth paths + the entry gate |
| Recorded at sign-in | `record_wallet_setup_state!` → `session[:wallet_setup]` (state) + `session[:wallet_setup_prompt]` (one-shot auto-open) |
| Read on render | `wallet_setup_required?` — RPC-free; feeds `walletSetupRequired` in the client session payload |
| The modal | `app/views/modals/_wallet_setup.html.erb` (Phantom row + explainer video + Detailed Guide) |
| Detecting a just-installed Phantom | `GET /wallet_probe` → `WalletProbeController`, framed hidden by the modal |
| Entry gate | `eligibilityBlocker` → `wallet_setup_required`; server-side refusal in `ContestsController#enter` |

Rules worth knowing:

- **A user holding a FREE ENTRY is left alone — once they have a wallet.** A
  gifted player already has the price of admission and needs no funding rail
  (operator call, 2026-09-09). Rule 2 still comes first, and claiming the gift is
  what clears it: `EntryGifts::Claim` mints the managed wallet (`reason: :gift`)
  even under web3-only onboarding, and the magic-link paths claim BEFORE they
  record the verdict. Two shapes then count: a minted entry token, **or a claimed
  `EntryGift` whose mint is still expected** (`mint_error` blank, so an admin
  claimant's unpayable gift buys no bypass — OPSEC-044). The verdict is computed
  once at sign-in and the claim is synchronous while `EntryGiftMintJob` is not,
  so a token-only test would read false and re-arm the modal for the whole
  session. Both halves fall away once the entry is spent.
- **A grandfathered web2 user holding ≥ `WalletSetupPolicy::MIN_USDC` (19) USDC
  is left alone.** 19 USDC is exactly one paid entry (`Contest::FORMATS`), so
  they can still play on their custodial rails and are never interrupted.
- **The prompt is dismissible** and re-opens at the entry gate.
- **The gate runs before the free-contest short-circuit.** Entry is an on-chain
  instruction, so a wallet-less account can't enter a free contest either.
- **With the flag off, none of it fires** — not the minting change, and not the
  policy. Web2 is a supported path then, and a "link Phantom" nudge would stand
  in front of the web2 funding rails that fix a low balance.
- Existing managed wallets are untouched either way: the flag gates **minting**,
  never the rails that serve wallets already out there.
- **Desktop extension installation has no callback Turf can register.** Chrome
  leaves the Web Store tab open after installation, and Phantom's
  `redirect_link` belongs to mobile deep links (the Browser SDK's redirect URL
  similarly serves OAuth providers, not an injected-extension install). The
  install row therefore opens Phantom in a new tab and preserves the originating
  Turf page. Its waiting message tells the player to finish setup there and
  return; the original tab keeps the exact contest and modal state.
- **A tab that was open when the user installed Phantom can never see it.**
  Chrome injects an extension only into documents created AFTER the install, and
  Phantom ships its provider as a `document_start` content script with no
  install-time sweep over open tabs. No amount of polling finds one, and there is
  no event to subscribe to — which is why every wallet doc says "refresh after
  installing". The modal used to do exactly that, and the reload threw away the
  user's scroll, card, and place in the signup.
- **`/wallet_probe` is how it detects one without reloading.** Phantom's manifest
  declares `all_frames`, so a *freshly loaded* same-origin iframe does get the
  provider. `WalletProbeController` serves an empty page that exists only to be
  that frame; the modal loads it hidden (cache-busted per attempt — a cached
  document predates the install) and reads `frame.contentWindow.phantom` across
  the same-origin boundary. Two things there are load-bearing and easy to undo
  by accident:
  - **It relaxes `frame-ancestors` from `'none'` to `'self'`**, per-controller,
    for that one page. The app-wide policy stays `'none'`
    (`test/controllers/wallet_probe_test.rb` asserts both halves). Remove the
    exemption and the browser silently refuses the frame: detection never fires,
    the row waits forever, and **nothing logs an error**.
  - **It inherits `ActionController::Base`, not `ApplicationController`**, so no
    filter (geo state, profile completion, session token, `allow_browser`) can
    redirect the frame onto a page whose CSP forbids framing — the same silent
    blindness by another route.
- **Detection is not capability.** The probe proves Phantom exists; this document
  still cannot call it. So Connect reloads once — carrying `walletSetupReopen` +
  `walletSetupAutoConnect` in `sessionStorage` and resuming straight into the
  signature prompt — because that is a moment where a page load reads as
  progress rather than as a glitch.

## Web3 step-up (web2 auth by a wallet account)

The intersection this names: an account that holds a **self-custody wallet**
signs in with a **web2 credential** — a magic link, email, or Google. Both facts
are ordinary alone; together they mean the person is signed in but cannot sign
anything on-chain.

`SessionContext` has modelled that intersection since it was lifted into
studio-engine — `web2?` (the session) AND `phantom_linked?` (the account) — but
nothing acted on it until 2026-08-21, so a wallet owner arriving by magic link
was logged straight in with no web3 beat at all. Google's path did notice, and
said so as a red sentence under the button that named the account's email
address. One standard now covers both.

| Piece | Where |
|-------|-------|
| The verdict | `Web3StepUpPolicy` — `required_for?(user, session_mode:)`, RPC-free |
| Wallet brand registry | `Solana::WalletProvider` (`phantom` / `solflare` / `backpack`) |
| Armed at sign-in | `record_web3_step_up_state!` → `session[:web3_step_up_prompt]` (one-shot) |
| Armed at the Google collision | `arm_web3_step_up_for(user)` — popup branch only |
| Armed at an entry refusal | `arm_web3_step_up_for(user)` again, from `ContestsController#enter` — see the ADVISORY note below |
| Read on render | `web3_step_up_required?` — helper, RPC-free, true for the whole session |
| The modal | `solana_studio/modals/_web3_step_up` — solana-studio owns the card; this app passes its own subtext + help route via `Web3StepUpHelper#web3_step_up_locals` |
| Brand memory | `users.web3_wallet_provider` + `web3_authenticated_at`, stamped by `User#record_web3_authentication!` |
| Showroom | `/admin/style#modals` — both states, against the real partial, including this app's own wording (the card takes its locals from `Web3StepUpHelper` on every render). The separate `/admin/modals/preview/web3-step-up` seam was retired 2026-09-09 |

Rules worth knowing:

- **It is ADVISORY, not an enforcement boundary** (operator call, 2026-08-21).
  A `true` opens a DISMISSIBLE card; it does not suspend the session. The teeth
  stay exactly where they were — `ContestsController#enter` still refuses an
  unsigned session and every on-chain path still demands a live signature — so
  this moves the PROMPT to sign-in without moving any gate, the same shape as the
  age gate's prompt moving to onboarding while its enforcement stayed at entry.
  Getting it backwards would lock a legitimate owner out of their own account
  over a wallet they merely cannot reach right now, which is why the card also
  carries a support link.
- **ONE CALLER READS THE VERDICT AS A GATE, and it is narrower than the verdict**
  (2026-09-07). `ContestsController#enter` refuses a PAID on-chain entry when the
  policy says `true` **AND** the account holds no custodial keypair
  (`!managed_wallet?`), returning `blocker.reason: "web3_step_up_required"` and
  re-arming the card. That is not the advice becoming enforcement — such an
  account has nothing to sign the entry with, so proceeding could only fail. The
  second clause is what keeps it narrow: a **combo** account (managed + linked
  wallet) gets the same `true` and enters anyway, from the custodial wallet
  `#resolve_web2_entry_funding!` deliberately spends from; and a **free** contest
  signs nothing, so it is never refused. Before this guard existed the same
  request fell through to that method's `raise "Managed wallet missing keypair
  (cannot sign entry)"`, and a player on QA read that exception text on a red
  card titled "Submitting Entry" with the step-up card sitting underneath it.
  `Solana::ErrorInterpreter` now maps that raise to the same blocker as a
  backstop, so no raise wording can reach a modal by any route.
- **It is disjoint from `WalletSetupPolicy`.** That policy asks "should this
  account GET a wallet"; this one asks "should this SESSION prove the wallet it
  already has" — opposite populations, since a `phantom_wallet?` account exits
  `WalletSetupPolicy` at its own step 1. A unit test pins the disjointness,
  because an overlap would stack two modals on one render.
- **It is NOT a chain step, deliberately.** `OnboardingFlow` answers "what is
  this ACCOUNT still missing" and its cards carry a 1-of-3 progress pill; a
  step-up asks what the SESSION owes, of a user whose account is already
  complete. Folding it in would put a returning wallet owner at "step 1 of 3" of
  an onboarding they finished months ago.
- **It HOLDS the chain rather than racing it.** Both are armed on the same
  render. The driver will not start the chain until the card dispatches
  `web3-step-up-dismissed`, and the chain payload stays in the DOM until then —
  so nothing is lost when the user dismisses. A successful signature never
  reaches that path: it reloads, and the server has already dropped both prompts
  (`clear_wallet_setup_state!`).
- **The brand memory is what makes it one click.** Without it the card can only
  offer the generic three-brand picker, so a returning Phantom user re-chooses
  Phantom every time. The browser sends the name it read off the Wallet Standard
  registration on every signature path (connect, re-auth, the Phantom mobile deep
  link, and `/account/link_solana`); `Solana::WalletProvider.normalize` is the
  only way it becomes a stored value, and an unknown brand stores nothing.
- **A null provider is a first-class state, not a bug.** Every wallet linked
  before the column existed has one, and there is no backfill — the brand is not
  recoverable from an address. Those users get the same card with the picker as
  its primary action.
- **The showroom is moving.** `/admin/modals` is DEPRECATED as a destination
  (operator direction, 2026-08-21): modal primitive work goes to the engine's
  living style guide at `/admin/style#modals`, where a modal is inherited by
  every Studio app instead of being turf's alone. The page still stands because
  5 modal ids have no card in the engine guide yet (`wallet-setup`,
  `wallet-changed`, `cdp-ramp`, `buy-entry-token`, `cosign-rejected`) — port
  first, delete second, so no state loses its review surface on the way out.
  A NAME LEAVES THIS LIST FOR ONE OF TWO REASONS, and they are not the same
  reason. Either the engine now OWNS the partial and shows its states (a true
  port, as `web3-step-up` was below), or this page turned out never to be that modal's
  review surface at all (it drew an EMPTY card). An engine SPECIMEN of a card
  turf still owns is neither: it does not review turf's partial, so it does not
  retire a name from this list. Measure against that bar, not against a
  matching id in the engine guide.
  2026-09-06 (/tasks/drop-dead-gallery-cards) took three names off by the
  SECOND route: `quest-success`, `unsubscribe-confirm` and `unsubscribe-goodbye`
  were registered in `layouts/application` but never in `layouts/modal_preview`,
  and `admin/modal_preview.html.erb` has no dynamic fallback, so each drew a
  blank card here. This page was never their showroom, so it is not holding one
  open for them. The same change dropped the five `Templates` cards (a TRUE
  port — the engine owns and cards `studio/modals/templates/*` itself) and the
  three remaining blank Quest / Newsletter cards (`free-entry-earned`,
  `newsletter-subscribe`, `newsletter-success`).
  `cosign-rejected` STAYS: it is registered once in `modals/_host_extras`, which
  studio-engine's host renders on every path, so it genuinely draws here.
  `web3-step-up` came off this list on 2026-08-24: the card had moved out of this
  app, and the engine's style guide shows both of its states — it renders
  solana-studio's real partial there, not a specimen copy — so its cards here were
  the duplicate rather than the review surface. The port is DONE rather than
  pending: solana-studio owns the partial now
  (`solana_studio/modals/_web3_step_up`).
- **The CTA is the STANDARD wallet row**, not a filled button — brand mark, the
  wallet's own name, `Installed` badge, chevron — the same shape the connect
  picker and the wallet-setup step use, so a wallet reads identically everywhere
  it is offered. It carries `pulse-cta` (engine-motion) because it is the one
  target on the card. Presence is POLLED rather than read once at mount:
  `walletProvider.available()` fills in asynchronously as wallets register and
  this card auto-opens right after auth, so a single early read would badge an
  installed wallet as missing.
- **Signing runs the wallet LOGIN, not the link path.** `linkMode` posts to
  `/account/link_solana`, which binds to the current user but never grants
  `session[:onchain]` — the thing the card exists to obtain. One inherited
  consequence: signing with a DIFFERENT wallet signs you into that wallet's
  account, exactly as the standalone Solana button already does. The card shows
  the truncated address so that is a visible choice rather than a surprise.

## The post-auth onboarding chain

One deliberate sequence after a successful auth, instead of modals firing
independently from three controllers (operator call, 2026-08-12; the welcome
step was retired 2026-08-15):

| # | Step | Modal | Outstanding while… |
|---|------|-------|--------------------|
| 1 | First name | `onboarding` | `first_name` is blank and not skipped this session |
| 2 | Age gate (DOB) | `age-verify` | `ENABLE_AGE_GATE` and `age_attested_at` is blank |
| 3 | Wallet setup | `wallet-setup` | `WalletSetupPolicy.required_for?` |

`OnboardingFlow` resolves the outstanding steps server-side; every auth-success
path calls `record_onboarding_state!`, which arms them one-shot on the session
(not the flash — the Google popup never redirects, so its opener's reload would
race a flash). The layout's **chain driver** owns the order: each step reports
the steps still remaining and the driver opens the next, so no modal knows what
follows it.

Rules worth knowing:

- **The chain opens on the first-name ask.** A `welcome` step ("You're in", with
  the auto-generated username) led it until 2026-08-15 and was retired: it cost a
  click to deliver something the user had not asked for. With one step left the
  `onboarding` modal's internal step machine went too — it is a single card
  taking no props, and signup and login now arm the SAME chain (there is no
  `welcome:` argument to `OnboardingFlow` any more). The older
  `magic-link-welcome` modal had already been RETIRED for a related reason: the
  chain greets every signup itself, which made that modal's only writer
  unreachable, and a modal nothing can open reads as a live alternative.
- **A WALLET signup walks the chain too, and used to walk nothing.**
  `SolanaSessionsController#verify` is create-or-login, and until 2026-08-21 it
  was the one auth-success path that never called `record_onboarding_state!`. A
  new Phantom account therefore met no chain at all: the first card it ever saw
  was whatever the contest entry gate raised — a birthday prompt, then a
  top-up — and it was never asked its first name. It now arms the chain like
  every other path, AFTER `clear_wallet_setup_state!` (which deletes the very
  session key the arming writes). A wallet signup resolves to first name → age;
  the wallet step drops out because the wallet they signed in with IS the setup.
- **No path may seed a placeholder name.** The same wallet signup used to build
  the account with `name: "anon"`, and `User#set_name_parts` copies `name` into
  `first_name` — so the account was born already holding a first name and step 1
  could never fire for it (`Studio.first_name_outstanding?` reads that column).
  Nothing needs the placeholder: `display_name` falls through
  username → name → email prefix → wallet → `"anon"` on its own. Accounts created
  before the fix still carry the literal `"anon"` and are never asked.
- **The first name is skippable IN THE CHAIN** (link *and* the ×), recorded in
  the session only — so a later visit may ask again while the field is blank. It
  never blocks the wallet step. It IS enforced at contest entry, though:
  `eligibilityBlocker` returns `first_name_required` ahead of every other gate,
  and that check reads the `first_name` COLUMN, so a session skip changes what we
  ask and not what we gate. The entry gate opens the same card with
  `{ required: true }`, which hides both skip affordances.
- **Moving the age PROMPT did not move the age GATE.** The chain is dismissible,
  so `ContestsController#enter` and `eligibilityBlocker` still refuse an
  unverified entry. That backstop is the compliance property of this change, not
  a redundancy — see `test/integration/onboarding_chain_test.rb`.
- **Opening the wallet step is idempotent.** After the age step, both the chain
  driver and the contest board's `age-verified` resume route to `wallet-setup`;
  both now no-op when it is already on the stack, so the fix does not depend on
  which fires first.
- **The chain does NOT announce its completion, and nothing waits for it.** An
  earlier revision had the driver fire `onboarding-chain-complete` and the contest
  board hold its tokens picker until then. It was withdrawn: the announcement ran
  SYNCHRONOUSLY inside the dispatching modal's `finish()`, before that modal's own
  `close()`, so a listener that opened a card in that window had it closed by the
  dispatcher instead — the picker was destroyed and a returning user was stranded
  on the first-name card. The picker can therefore still land on top of a walking
  chain (a cosmetic stack). Who owns the screen after the chain, and after age
  verification where the board runs its own resume, is an open design question.
- **The showroom** is `/admin/modals` → **Flows** (`AdminController::MODAL_FLOWS`),
  which walks the steps on the live modal host. It is pinned to
  `OnboardingFlow::STEPS` by a test, so a new step cannot go unshown. These
  flows are intended to move to the engine's `/admin/style#modals` later, which
  needs a studio-engine release plus a pin bump in turf.

## Account Management

`AccountsController` owns profile, identity, and account-level wallet actions:

- `GET /account` - account settings and identity overview.
- `PATCH /account` - profile update, first email set, or out-of-band email-change request.
- `GET /account/complete_profile` and `POST /account/save_profile` - avatar/profile completion.
- `POST /account/link_solana` - link a Phantom wallet to the current account after a session-bound signature.
- `POST /account/unlink_google` - remove Google OAuth identity.
- `PATCH /account/set_inviter` - one-time inviter/referral binding.
- `POST /account/update_username` and `POST /account/confirm_username` - on-chain username edit.
- `GET /account/session_state` and `GET /account/session_refresh` - client rehydrate endpoints.
- `POST /account/initiate_wallet_export` - send the self-custody export link to the verified email address.

Email changes are out-of-band. Changing an existing email mints a signed token
and emails the current address; the address changes only after the human POSTs
from the confirmation page. Wallet export also uses a signed emailed token and
requires a managed, non-self-custodied account with a verified email.

Identity mutations are blocked while an admin is impersonating another user.

## On-Chain Usernames

Every user gets a DB username and an on-chain `UserAccount` PDA whose username
field mirrors it.

Signup callbacks:

- `before_validation :ensure_username, on: :create` fills `users.username`.
- `after_commit :enqueue_onchain_account_setup, on: :create` enqueues
  `CreateOnchainUserAccountJob`.

Username edits are gated by `User#can_change_username?`, which requires a
connected wallet and at least one contest entry.

Edit flow:

- Managed-wallet users call `POST /account/update_username`; the server signs
  `set_username` and mirrors the DB column.
- Phantom or self-custodied users call `POST /account/update_username`, receive
  a partial transaction, sign in the wallet, then call
  `POST /account/confirm_username`; the server verifies the transaction before
  mirroring the DB column.

## Admin Authorization

- `role` string column on `users`, default `"viewer"`.
- `User#admin?` returns `role == "admin"`.
- `require_admin` comes from `Studio::ErrorHandling`.
- Sidekiq Web has an extra local middleware that requires both admin role and a
  matching `session_token`.

Seeded operator account: `alex@mcritchie.studio`.

## SSO Satellite Role - Removed 2026-05-24

Turf Monster does not accept McRitchie Studio SSO today. Cookie isolation and
local controller overrides make `sso_login` and `sso_continue` return 404.

What changed:

- `config/initializers/session_store.rb` uses an app-specific `_turf_session`
  cookie with no shared `.mcritchie.studio` domain.
- `SessionsController` overrides SSO actions and disables them.
- The old SSO continue partial was removed from the local sign-in view.

Do not restore SSO until the hub/satellite cookie contract is deliberately
redesigned and hardened.

## Route Gotchas

`resource :account` member routes put the action name first. For example,
`unlink_google_account_path` is correct; `account_unlink_google_path` is not.

`/signin` is the canonical human auth page. `POST /login` exists only because
the engine route remains drawn; the local controller redirects stale password
posts back to `/signin` with a magic-link hint.
