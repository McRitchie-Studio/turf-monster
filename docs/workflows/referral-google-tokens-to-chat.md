# Workflow: Referral link → Google signup → buy tokens → enter → chat

> **Code is law.** Every claim below cites `path/to/file.rb:NN` from the current
> codebase. When porting from another MD, verify against the code first — line
> numbers drift, prose rots. When code moves, this file moves with it: re-confirm
> citations on edit.

**Trigger:** Visitor clicks a marketing link like `/lp/:slug` (or any URL with
`?reference=…`) for a paid on-chain contest. There is no `/landing/:slug` route; older
`/l/:slug` links still land, as the trigger note in [[web3-landing-to-entry]] explains.
**Actors:** Visitor → Google OAuth → Rails (`LandingPagesController` / `OmniauthCallbacksController` / `TokensController` / `ContestsController` / `MessagesController`) → Stripe → Sidekiq (`TokenPurchaseJob`) → Solana RPC (managed-wallet `mint_entry_token` + `enter_contest_with_token`) → ActionCable.
**Outcome:** `users` row with `reference = "<landing-slug>"`, a `stripe_purchases` row in status `minted` with 3 on-chain `EntryTokenAccount` PDAs (one consumed), an `entries` row in status `complete` with `onchain_tx_signature`, a `messages` row broadcast on `[contest, :messages]`.
**Preconditions:** Contest is `open`, `onchain`, has `chat_enabled = true` (default — `db/schema.rb:66`), and is backed by a configured `SeasonConfig.current_season_id` (`contests_controller.rb:296`). Stripe enabled. Visitor not in a blocked geo state.

## Sequence

1. **Visit landing page (first touch)** — `app/controllers/landing_pages_controller.rb:18`
   - `cookies[:reference] = { value: @landing_page.slug, expires: 30.days }` (only if blank — an explicit `?reference=` already captured by `ApplicationController#capture_reference` at `app/controllers/application_controller.rb:51-56` wins). Cookie lives 30 days across the funnel.
2. **Click CTA → contest show page** — `app/controllers/contests_controller.rb:222` (`#show`, public via `skip_before_action :require_authentication` on line 4). Renders `app/views/contests/show.html.erb` which mounts the inline matchup board `_turf_totals_board.html.erb`.
3. **Guest selects 6 picks, attempts to enter** — `app/views/contests/_turf_totals_board.html.erb:899` (`confirmEntry()`). Picks live in Alpine state (`selections` / `selectionOrder`); no server cart is persisted yet for guests. Lines 901-904: `Alpine.store('session').isGuest === true` → calls `showLoginModal()`.
4. **Auth modal opens at `credentials` step** — `app/views/contests/_turf_totals_board.html.erb:390-402` opens `Alpine.store('modals').open('auth', { step: 'credentials', mode: 'signup', … })`. Wizard partial: `app/views/modals/_auth.html.erb`. Cart is snapshot to `sessionStorage` via `saveCartForRedirect()` at `app/views/contests/_turf_totals_board.html.erb:406-415` before any external redirect.
5. **"Sign up with Google" clicked** — `app/views/modals/_auth.html.erb:106` dispatches `auth-google-click` → `app/views/contests/_turf_totals_board.html.erb:598` `loginWithGoogle()` opens `/auth/google_popup` in a 500x650 popup. If blocked, falls back to full-page form POST `/auth/google_oauth2` at line 649-661 (cart still saved).
6. **Google round-trip + OmniAuth callback** — `app/controllers/omniauth_callbacks_controller.rb:22` (`#create`). Server re-checks the id_token against Google's tokeninfo endpoint via `GoogleOauthValidator` (line 28; OPSEC-005). `User.from_omniauth(auth, email_verified: true)` at `app/models/user.rb:50` creates the row. `after_create :generate_managed_wallet!` (`user.rb:23, 237-257`) generates an ed25519 managed wallet — no RPC. `after_commit :enqueue_onchain_account_setup, on: :create` (`user.rb:27, 317-319`) enqueues `CreateOnchainUserAccountJob` to async-create the on-chain `UserAccount` PDA + username.
7. **Reference attribution + redirect to tokens-buy** — `app/controllers/omniauth_callbacks_controller.rb:95-98` writes `cookies[:reference]` onto `users.reference` and deletes the cookie. `set_app_session(result)` at line 101 sets `session[:turf_user_id]` + `session[:session_token]`. Line 104: new signups redirect to `tokens_buy_path` (popup mode posts a closer-page message — line 130-137 — and the contest tab reloads, restoring the cart from `sessionStorage`; full-page redirect users land directly on `/tokens/buy`).
8. **In-modal token pack picker → Stripe Checkout** — `app/controllers/tokens_controller.rb:11` (`#stripe_checkout`). User picks `trio` (3 tokens for $4900 — `app/models/stripe_purchase.rb:14-15`). Server creates a Stripe Checkout Session (`tokens_controller.rb:36-65`) with `metadata = { kind: "tokens", user_id, pack_id, quantity, wallet_address, contest_slug }`, `success_url = /tokens/processing?session_id={CHECKOUT_SESSION_ID}&contest=<slug>`. JSON response returns `url` so the in-modal fetch opens Stripe in a new tab (line 75 comment).
9. **Stripe payment → webhook** — `app/controllers/webhooks/stripe_controller.rb:8` (`#create`, CSRF + auth skipped on lines 3-6). `Stripe::Webhook.construct_event` verifies signature (line 14). `event.type == "checkout.session.completed"` routes to `handle_checkout_completed` (line 66): `StripeCheckoutValidator` re-fetches the session and asserts `payment_status` / `livemode` / `kind` / `amount` (line 75 — OPSEC-008/032/033). Validated metadata then enqueues `TokenPurchaseJob.perform_later(...)` at line 89.
10. **On-chain token mint (the "minted" step is real on-chain, not DB)** — `app/jobs/token_purchase_job.rb:16`. Loop at line 65-77 calls `Solana::Vault#mint_entry_token(wallet_address:, source: :stripe, source_ref: "stripe:#{session_id}:#{i}")` (definition at `app/services/solana/vault.rb:992`). Each mint creates an on-chain `EntryTokenAccount` PDA owned by the user's managed wallet. Signatures persist incrementally to `stripe_purchases.mint_tx_signatures` after every mint (line 75) so a mid-loop crash resumes at `already_minted = signatures.length` (line 57-59). On success: `purchase.mark_minted!(signatures)` at line 80.
11. **Entry resumption (no Stripe redirect for the user)** — `/tokens/processing` (`app/views/tokens/processing.html.erb`) is the Stripe `success_url`. The new tab `BroadcastChannel('tt-tokens').postMessage({ status: 'returned', sessionId })` at line 87-91 + `window.opener.postMessage` fallback at line 94-101 hand control back to the contest tab. Contest tab listener at `app/views/contests/_turf_totals_board.html.erb:115-154` flips the modal to `tokens-confirming` and runs `pollTokenStatus(sessionId)` (line 717-772) hitting `GET /tokens/status` (`tokens_controller.rb:98-108`). When `status == "minted"`, the modal transitions to step `tokens-minted` (board line 741) which renders the in-modal Hold to Confirm button.
12. **Hold to Confirm fires entry submission** — `window` event `hold-confirm-entry` → `confirmEntry()` at `app/views/contests/_turf_totals_board.html.erb:899`. Web2 (managed-wallet) branch: POST `/contests/:slug/enter` (line 1040). The cart picks were replayed to the server via `replaySelectionsToServer()` (line 666-...) right after signup (line 475 — survives the Stripe detour because they're cart rows in Postgres at that point). Token consumption happens server-side: `ContestsController#enter` at `app/controllers/contests_controller.rb:311-335` resolves `current_user.next_unconsumed_entry_token`, calls `Solana::Vault#enter_contest_with_token` — atomic on-chain instruction that consumes the token PDA + creates the entry PDA + awards seeds in one TX. `entry.confirm!(tx_signature:, onchain_entry_id:)` at line 348 transitions cart → complete.
13. **Redirect lands on contest page** — `contests_controller.rb` returns `redirect: contest_path(@contest)` in JSON. `tokens-submitted` step renders `_entry_confirmed` card (`app/views/modals/auth/_tokens.html.erb:110-116`) with the CTA. The user lands on `ContestsController#show` — which renders `_chat_panel` (`app/views/contests/show.html.erb:154`).
14. **Send first chat message** — `app/views/contests/_chat_panel.html.erb:128-136` (`send()`) POSTs JSON `{ message: { body } }` to `contest_messages_path(contest)`. Route: `config/routes.rb:172` (`resources :messages, only: [:create, :destroy]` nested under contest). Handler: `app/controllers/messages_controller.rb:8` (`#create`). Gates: `chat_enabled?` before_action (line 5, 55-58), `chat_participant?(current_user)` check at line 9 (definition `app/models/contest.rb:424-428` — admin OR active/complete entry). Per-user 5-msg-per-15s rate limit at `messages_controller.rb:62-67`.
15. **Real-time broadcast** — `app/models/message.rb:17` `after_create_commit :broadcast_new_message` → `broadcast_prepend_to([contest, :messages], target: "contest_#{contest_id}_messages", partial: "messages/message", locals: { message: self })` (line 43-49). Browser subscribes via `<%= turbo_stream_from contest, :messages %>` at `app/views/contests/_chat_panel.html.erb:16`. Turbo Streams over ActionCable — no custom channel class.

## Data touched

- `users` (insert) — `email`, `name`, `provider="google_oauth2"`, `uid`, `email_verified_at`, `username` (auto-gen), `web2_solana_address`, `encrypted_web2_solana_private_key`, `session_token`. `reference` written immediately after via `update_column` (`omniauth_callbacks_controller.rb:96`).
- `cookies[:reference]` (read/write — `landing_pages_controller.rb:18`, `application_controller.rb:55`, deleted in `omniauth_callbacks_controller.rb:97`).
- `session[:turf_user_id]` + `session[:session_token]` (write, via `set_app_session` — `application_controller.rb:19-28`).
- `stripe_purchases` (insert + updates) — `stripe_session_id`, `quantity=3`, `price_cents=4900`, `status: pending → minted`, `mint_tx_signatures` (incremental JSON array — `token_purchase_job.rb:75`).
- `entries` (insert as `cart`, then update to `complete`) — via `replaySelectionsToServer` (cart toggles) and `entry.confirm!` (`contests_controller.rb:348`). `onchain_tx_signature`, `onchain_entry_id`, `entry_number` written.
- `selections` (insert × 6) — `replaySelectionsToServer` POSTs `toggle_selection` for each saved id.
- `transaction_logs` (insert) — `token_purchase_job.rb:83-91` with `type="token_purchase"`, `direction="credit"`.
- `outbound_requests` (insert) — every Stripe API + Solana RPC call from this flow auto-logs via `Stripe::Instrumentation` + `Solana::ClientLogger`.
- `messages` (insert) — `body`, `user_id`, `contest_id`. `hidden_at` stays `NULL`.
- `sessionStorage.pendingContestEntry` (browser-only) — picks snapshot for resumption (`_turf_totals_board.html.erb:408`).
- on-chain: `EntryTokenAccount` PDA × 3 via `mint_entry_token` (signer: vault admin keypair). `EntryAccount` PDA + `UserAccount` PDA seeds bump via `enter_contest_with_token` (signer: vault admin + user managed keypair). `UserAccount` PDA initial create via `CreateOnchainUserAccountJob` async.
- external: Google `tokeninfo` GET (OPSEC-005), Stripe `Checkout::Session.create` + webhook + `Checkout::Session.retrieve` (validator re-fetch).

## Failure modes

- **Reference cookie collision** — landing page only sets if `cookies[:reference].blank?` (`landing_pages_controller.rb:18`), and `ApplicationController#capture_reference` likewise no-ops if present (`application_controller.rb:53`). First touch wins; later landing visits leave the cookie alone. → silent; correct behaviour.
- **Google email already linked to unverified existing user** — `User.from_omniauth` returns `:requires_verification` (`user.rb:62-63`). Controller surfaces "verify your existing account first" alert (`omniauth_callbacks_controller.rb:90-91`). No silent merge (OPSEC-005). Reference stays in the cookie for the eventual signup.
- **Profile not complete** — N/A on this app: `ensure_username` auto-fills the username via `Studio::UsernameGenerator.generate` at `user.rb:312-314`, so `profile_complete?` is always true post-create.
- **Stripe webhook signature mismatch / replay** — `Webhooks::StripeController#create` returns 400 on bad signature (line 19-20) and 200 + log on test-event-in-production (line 29-32). Validator rejects mismatched payment_status/livemode/kind/amount with logged `validator_rejected` (line 77-80).
- **Partial mint failure (1 of 3 tokens minted, RPC crashes)** — `TokenPurchaseJob` persists each signature before continuing (`token_purchase_job.rb:75`). On Sidekiq retry, loop resumes at `already_minted = signatures.length` (line 57-59). `mark_failed_unless_minted!` (line 99) never downgrades a `minted` row.
- **User refreshes during the Stripe round-trip** — cart picks already POSTed to the server as cart-status `entries` + `selections` rows by `replaySelectionsToServer` (`_turf_totals_board.html.erb:475`). The processing-tab `BroadcastChannel` won't reach a closed contest tab, but the next contest visit reads cart rows back from the DB. On-chain mint completes regardless (job is async).
- **`/tokens/status` polling times out (>45s)** — modal flips to `tokens-error` (`_turf_totals_board.html.erb:761-768`) with "Refresh in a moment" copy.
- **`ContestsController#enter` race — contest full mid-flight** — `with_lock` at `contests_controller.rb:288` + `active_count >= @contest.max_entries` check at line 290 raises "Contest is full"; the response 422s and the modal surfaces the error.
- **Chat message rate-limit hit** — `MessagesController#posting_too_fast?` returns 429 (`messages_controller.rb:14`). User sees "You're posting too fast" in the composer.
- **ActionCable broadcast failure** — `Message#broadcast_new_message` wraps in `rescue` and logs to `ErrorLog` (`message.rb:50-51`) so the controller request still returns `{ ok: true }`. Other subscribers miss the message; the poster sees it (Turbo Drive renders locally via the controller response — actually no, this isn't ideal; the local sender also waits on the broadcast). → Inspect `error_logs` for `Message` targets.
- **Chargeback / refund post-mint** — `handle_dispute` / `handle_refund` in `webhooks/stripe_controller.rb:111-136` flag the user (`payment_risk_flag`) and freeze them (`freeze_for_payment_risk!`). Future buys + entries blocked; operator unfreezes via console.

## Related workflows

- [[admin-contest-setup]] — produces the `Contest` + `LandingPage` records this flow depends on (the `?reference=` cookie target).
- [[web3-landing-to-entry]] — alternate path: Phantom signup instead of Google, on-chain entry via `prepare_entry` / `confirm_onchain_entry` (signed by Phantom, not managed wallet).
- [[email-signup-token-to-chat]] — alternate signup lane: email magic link instead of Google OAuth; same `tokens-picker` → on-chain mint tail.

---

<!--
Cite-density notes for the next agent:
- Post-entry redirects go straight to `contest_path` — there is no separate lobby template/route. Old `/c/:slug/lobby` permalink was removed 2026-05-24.
- Webhook → mint is one-way; the user never sees `/tokens/processing` if their contest tab is still open (BroadcastChannel hand-off). The processing page is the fallback for closed-tab cases.
- `chat_participant?` requires `:active` or `:complete` entry status. Cart-stage entries don't count — verify the entry.confirm! call landed before troubleshooting "can't chat" reports.
-->
