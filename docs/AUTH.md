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

When the flag is off, the shared checkbox partial renders nothing, client auth
models initialize as already attested, server signup gates pass, and
`age_attested_at` is intentionally not stamped. When the flag is on, brand-new
magic-link, Google, wallet, and fallback `POST /signup` creations must carry the
attestation.

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
`walletConnected` in the session payload, which IS `solana_connected?`. Do not
branch on `mode`: a wallet-less account reads `"web2"`.

| Piece | Where |
|-------|-------|
| The flag | `AppFlags.web3_only_onboarding?` |
| Wallet minting skipped | `User#generate_managed_wallet!` early-returns |
| Who gets prompted | `WalletSetupPolicy` — one rule, both auth paths + the entry gate |
| Recorded at sign-in | `record_wallet_setup_state!` → `session[:wallet_setup]` (state) + `session[:wallet_setup_prompt]` (one-shot auto-open) |
| Read on render | `wallet_setup_required?` — RPC-free; feeds `walletSetupRequired` in the client session payload |
| The modal | `app/views/modals/_wallet_setup.html.erb` (Phantom row + install guide) |
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
