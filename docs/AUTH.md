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
| the Connect-Wallet picker | `WalletPickerHelper#wallet_connect_modal_locals` passes the engine picker a `slot:` — or `nil` when the flag is parked |

The picker is studio-engine's (`studio/modals/_wallet_connect`) as of
/tasks/adopt-turf-engine-picker, so its attestation arrives as that partial's
`slot` local rather than an inline render.

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

The mobile deep link itself is **studio-engine's** since
`adopt-engine-phantom-deeplink`: `studio/solana/_phantom_deeplink` publishes
`window.startPhantomDeepLink` and `solana_sessions/phantom_callback` completes the
return leg. Turf renders the deep link once from `shared/_alpine_factories` (one
callsite, both layouts that mount the wallet picker), keeps its own blocking
tweetnacl tag rather than the engine's async `studio/solana/deeplink_assets`, and
opts the callback's debug sink back on with
`Studio.wallet_debug_sink = -> { !AppFlags.live_production? }`.

**The two layouts load that tag on different terms, and the difference bites.**
`layouts/application` loads tweetnacl on every page. `layouts/modal_preview` gates
it per modal id, because loading web3.js and tweetnacl in all 49 gallery iframes
stalled the page. Rendering the deep link is unconditional either way, so a
preview card always publishes `window.startPhantomDeepLink` — and the engine
picker paints its mobile Phantom row on that global merely EXISTING. A card that
publishes the global without the tag therefore paints a row whose tap throws
`nacl is not defined` synchronously, before the fetch, where nothing catches it.
That is `/tasks/preview-gallery-deeplink-dead`. `phantom_deeplink_adoption_test`
derives the ids that owe the tag from the preview layout's own registrations —
the deep-link callers plus anything that reaches one through `swap`/`open` hops,
failing closed on a target it cannot read — and fails when the gate is narrower.
The derivation is scoped to that one layout by name: a THIRD layout rendering
`shared/_alpine_factories` owes tweetnacl too, and nothing asserts it.

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
| Who gets prompted | `WalletSetupPolicy` — one rule, both auth paths + the entry gate |
| Recorded at sign-in | `record_wallet_setup_state!` → `session[:wallet_setup]` (state) + `session[:wallet_setup_prompt]` (one-shot auto-open) |
| Read on render | `wallet_setup_required?` — RPC-free; feeds `walletSetupRequired` in the client session payload |
| The modal | `app/views/modals/_wallet_setup.html.erb` (Phantom row + explainer video + Detailed Guide) |
| Detecting a just-installed Phantom | `GET /wallet_probe` → `WalletProbeController`, framed hidden by the modal |
| Entry gate | `eligibilityBlocker` → `wallet_setup_required`; server-side refusal in `ContestsController#enter` |

Rules worth knowing:

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
| Read on render | `web3_step_up_required?` — helper, RPC-free, true for the whole session |
| The modal | `studio/modals/_web3_step_up` — studio-engine owns the card; this app passes its own subtext + help route via `Web3StepUpHelper#web3_step_up_locals` |
| Brand memory | `users.web3_wallet_provider` + `web3_authenticated_at`, stamped by `User#record_web3_authentication!` |
| Showroom | `/admin/style#modals` — both states, against the real partial. This app's own wording renders at `/admin/modals/preview/web3-step-up` |

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
  8 modal ids have no card in the engine guide yet (`wallet-setup`,
  `wallet-changed`, `cdp-ramp`, `buy-entry-token`, `cosign-rejected`,
  `quest-success`, `unsubscribe-confirm`, `unsubscribe-goodbye`) — port first,
  delete second, so no state loses its review surface on the way out.
  `web3-step-up` came off this list on 2026-08-24: the engine owns the partial
  AND shows both of its states, so its cards here were the duplicate rather than
  the review surface. This card's own port into
  `studio/modals/` as a shared engine partial is the next step for it.
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
