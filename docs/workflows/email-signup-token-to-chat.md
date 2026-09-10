# Workflow: email magic-link signup -> token -> chat

> Legacy Stripe path. Stripe checkout is retired by default; this workflow is
> still useful when explicitly reviving `PAYMENT_PROVIDER=stripe` for historical
> compatibility or regression testing. Re-confirm whether PayPal, CDP, or direct
> USDC entry is now the intended flow before using this as live product context.

> **Code is law.** Every claim below cites `path/to/file.rb:NN` from the current
> codebase. Re-confirm citations on edit — line numbers drift on refactor.

**Trigger:** Anonymous visitor opens `/` (`GET /`)
**Actors:** User / Rails / email transport / Stripe / Sidekiq / Solana RPC (devnet)
**Outcome:** New `users` row, server-managed wallet generated, on-chain `UserAccount` PDA created, one Stripe-funded on-chain `EntryTokenAccount` minted and consumed, an `entries` row for the main contest in status `active` with 6 `selections`, and one visible `messages` row broadcast over ActionCable to that contest's chat stream.
**Preconditions:** at least one contest in status `open`/`settled` exists (otherwise root falls back to `/contests`; `locked` is no longer a status — it's a derived time-gate); `PAYMENT_PROVIDER=stripe` plus Stripe keys set (`Rails.application.config.x.stripe_enabled`); a `SeasonConfig` row exists with a non-zero `current_season_id` (`contests_controller.rb:297`); the chosen contest is on-chain (token entry requires `contest.onchain?` — see `contests_controller.rb:311`).

## Sequence

1. **Visitor lands on `/`** — `config/routes.rb:57` → `ContestsController#world_cup` (`app/controllers/contests_controller.rb:568`).
   - Skipped from `:require_authentication` for logged-out browsing (`contests_controller.rb:4`).
   - Picks the contest in this order: `SeasonConfig.main_contest_explicit` → `SeasonConfig.main_contest` (open-only fallback, `app/models/season_config.rb:33-37`) → most recent `open/settled` contest (`contests_controller.rb:215-217`; `locked` dropped from the status enum).
   - 302s to `contest_path(@contest)` (`contests_controller.rb:219`).

2. **Show page renders for logged-out visitor** — `ContestsController#show` (`contests_controller.rb:222`) → `app/views/contests/show.html.erb`.
   - Hero banner + creator avatar + on-chain explorer link — `app/views/contests/show.html.erb:26` renders `contests/_hero` (`app/views/contests/_hero.html.erb:19` is the explorer link, `:28` the creator avatar).
   - Inline matchup board partial `app/views/contests/_turf_totals_board.html.erb` never links out to `/tokens/buy`: the buy affordance is the IN-MODAL entry-token picker, `showBuyEntryToken()` (`app/views/contests/_turf_totals_board.html.erb:1243`), so the buyer never visually leaves the contest. An anonymous visitor is routed through the auth modal first and resumed onto the picker afterwards (`app/views/contests/_turf_totals_board.html.erb:415-417`); the entry fee itself is handed to the board as `entryFeeCents` (`app/views/contests/_turf_totals_board.html.erb:142`).

3. **Clicks "Sign in" in the navbar** — the logged-out CTA targets the unified `/signin` page. Legacy `GET /login` and `GET /signup` redirect there.

4. **Requests an email magic link** — `SessionsController#new` renders the unified auth surface; the email form posts to `POST /magic_link`.
   - `MagicLinksController#create` validates the email shape, creates a one-time `MagicLink`, and sends `UserMailer.magic_link` through `Studio::Email`.
   - The response is uniform for well-formed requests so the endpoint does not enumerate accounts.

5. **Consumes the magic link** — the emailed URL first hits inert `GET /magic_link/:token`, then the human confirmation form POSTs to `POST /magic_link/:token`.
   - `MagicLink.consume` burns the token once.
   - If the user does not exist, `MagicLinksController#sign_up_new` builds `User.new(email: result.email)`.
   - `@user.save!` triggers the shared spine on `User` (see [[referral-google-tokens-to-chat]] for the equivalent flow on the Google path):
     - `before_validation :ensure_username, on: :create` (`app/models/user.rb:20`) → `Studio::UsernameGenerator.generate` fills `username` (`user.rb:312-314`).
     - `before_create :set_initial_session_token` (`user.rb:22`) writes `users.session_token` (OPSEC-045 cookie-binding).
     - `after_create :generate_managed_wallet!` (`user.rb:23`) → `Solana::Keypair.generate` (local ed25519, **no RPC**), encrypts with `MANAGED_WALLET_ENCRYPTION_KEY`, writes `web2_solana_address` + `encrypted_web2_solana_private_key` (`user.rb:237-257`). Skipped for admins (`user.rb:244`).
     - `after_commit :enqueue_onchain_account_setup, on: :create` (`user.rb:27`) → `CreateOnchainUserAccountJob.perform_later(id)` (`user.rb:317-319`). Async — user is logged in before the PDA settles.
   - `set_app_session(@user)` writes `session[:turf_user_id]`, `session[:session_token]`, and clears stale `session[:onchain]`.
   - Magic-link consume proves email ownership, so `email_verified_at` is stamped for new and previously-unverified existing users.

6. **Buy 1 token via Stripe** — `TokensController#buy` (`app/controllers/tokens_controller.rb:7-9`) renders `app/views/tokens/buy.html.erb`.
   - Pack catalog: `StripePurchase::PACKS` (`app/models/stripe_purchase.rb:13-20`) — `"single"` = 1 token, `19_00` cents. The 3-token bundle (`"trio"`, `49_00`) shares the same checkout path with a different `pack_id`. `"test_trio"` ($5) is gated by `ENABLE_TEST_SCAFFOLDING` (`stripe_purchase.rb:39-41`).
   - Pack button form `POST /tokens/stripe_checkout?pack=single` → `TokensController#stripe_checkout` (`tokens_controller.rb:11-83`).
   - Gates: `require_login` (`tokens_controller.rb:135-138`), `require_unfrozen_account` (OPSEC-048, `tokens_controller.rb:5`), `solana_connected?` check (`tokens_controller.rb:16-18`), `stripe_enabled` boot flag (`tokens_controller.rb:19-21`), `payment_risk_flag` chargeback block (`tokens_controller.rb:24-26`).
   - Wrapped in `rescue_and_log(target: current_user)` (`tokens_controller.rb:35`). Creates `Stripe::Checkout::Session` with `metadata.kind = "tokens"` and `metadata.wallet_address = current_user.solana_address` (`tokens_controller.rb:36-65`); `success_url` is `tokens_processing_url?session_id={CHECKOUT_SESSION_ID}` (`tokens_controller.rb:47-49`). 302s to Stripe (`tokens_controller.rb:69`).

7. **Stripe webhook credits the token on-chain** — `POST /webhooks/stripe` → `Webhooks::StripeController#create` (`app/controllers/webhooks/stripe_controller.rb:8-62`).
   - Skips `:require_authentication`, `:detect_geo_state`, `:require_profile_completion` (`stripe_controller.rb:3-6`).
   - `Stripe::Webhook.construct_event` verifies the signature (`stripe_controller.rb:14`); OPSEC-033 rejects test-mode events in prod (`stripe_controller.rb:29-32`).
   - `checkout.session.completed` → `handle_checkout_completed` (`stripe_controller.rb:34-50, 66-108`):
     - `StripeCheckoutValidator.new(stripe_session_id, kind: "tokens").call` re-fetches the session and validates `payment_status` / `livemode` / `kind` / `amount` (`stripe_controller.rb:75`).
     - `TokenPurchaseJob.perform_later(...)` enqueues (`stripe_controller.rb:89-95`).
   - `TokenPurchaseJob#perform` (`app/jobs/token_purchase_job.rb:19-101`):
     - Find-or-create `StripePurchase` row (`token_purchase_job.rb:38-46`).
     - `Solana::Vault#mint_entry_token` once per quantity with `source: :stripe, source_ref: "stripe:#{session_id}:#{i}"` (`token_purchase_job.rb:67-72`).
     - Each successful signature is persisted to `purchase.mint_tx_signatures` **inside the loop** (`token_purchase_job.rb:73-76`) — partial-failure resume relies on this (`token_purchase_job.rb:54-66`).
     - `purchase.mark_minted!(signatures)` (`app/jobs/token_purchase_job.rb:138`) + `TransactionLog.record!` audit row (`app/jobs/token_purchase_job.rb:151-159`).
     - Failures call `mark_failed_unless_minted!` (H8 audit fix — `app/models/concerns/mintable_purchase.rb:36-40`, mixed into `StripePurchase` at `app/models/stripe_purchase.rb:7`) and re-raise so Sidekiq retries.
   - Browser polls `/tokens/status` from the `processing` page (`tokens_controller.rb:98-108`) until `purchase.status == "minted"`, then renders the success card with the contest CTA.

8. **Back to root → main contest** — user clicks the navbar "Turf Monster" home link → `GET /` → step 1 repeats → 302 to `contest_path(@contest)`.
   - Same `world_cup` action; same `SeasonConfig.main_contest_explicit` → fallback chain (`contests_controller.rb:215-217`).
   - "Main contest" surfacing logic = the admin's explicit pick in `/admin/site_config` (set via `SeasonConfig.set_main_contest!`, `season_config.rb:45-48`), then `main_contest`'s open-only fallback, then most-recent of `[:open, :settled]`. **No** highest-pot ordering.

9. **Build a 6-pick lineup** — for each tap on a matchup tile, the board POSTs to `ContestsController#toggle_selection` (`contests_controller.rb:652-673`).
   - Rejects if contest not `open?` (`contests_controller.rb:653-655`).
   - `find_or_create_by!(user: current_user, status: :cart)` creates a cart `Entry` on the first toggle (`contests_controller.rb:660`).
   - `entry.toggle_selection!(matchup)` enforces the cap of `contest.picks_required` (= 6, see `app/models/entry.rb:29-50`).
   - Wrapped in `rescue_and_log(target: entry, parent: @contest)` (`contests_controller.rb:662`).

10. **Hold-to-Confirm fires `POST /contests/:id/enter`** — `ContestsController#enter` (`contests_controller.rb:261`).
    - Gated by `require_geo_allowed` + `require_unfrozen_account` (`contests_controller.rb:7-9`).
    - Loads the cart entry (`app/controllers/contests_controller.rb:704`); web2/managed funding branch runs inside `#enter`'s `@contest.with_lock` (`app/controllers/contests_controller.rb:821`, helper documented at `:1801-1812`):
      - `current_user.next_unconsumed_entry_token` reads on-chain (`user.rb:300-306`); raises `"No entry tokens. Buy at /tokens/buy"` if none (`contests_controller.rb:316`).
      - `Solana::Vault#enter_contest_with_token(wallet, contest.slug, entry_number, token[:pda], user_keypair:, season_id:)` — atomic Anchor instruction: creates entry PDA, consumes token, awards seeds (`contests_controller.rb:325-332`). The managed wallet's keypair (decrypted from DB) signs (`user.rb:232-235`).
    - `entry.confirm!(tx_signature:, onchain_entry_id:)` validates 6 selections, checks lock time, refuses duplicate selection combos, writes a `TransactionLog` `entry_fee` debit row, and flips `entries.status` → `active` (`app/models/entry.rb:62-110`).
    - All inside `@contest.with_lock { ... }` (`contests_controller.rb:288-349`).
    - JSON redirect to `contest_path(@contest)` (`contests_controller.rb:376`).

11. **Land back on the contest show page** — now `@has_entry == true` so the seeds + share cards render (`app/views/contests/show.html.erb:34-57`) and the leaderboard partial replaces the matchup board. The same page hosts the chat panel `app/views/contests/_chat_panel.html.erb`.

12. **Send a chat message** — composer in `_chat_panel.html.erb:30-` POSTs `contest_messages_path(contest)` → `MessagesController#create` (`app/controllers/messages_controller.rb:7-30`).
    - `before_action :set_contest` (`messages_controller.rb:50-53`) + `:require_chat_enabled` (`messages_controller.rb:55-58`, reads `contest.chat_enabled?` — a DB column predicate).
    - `chat_participant?(current_user)` requires `admin?` or an `active`/`complete` entry (`app/models/contest.rb:424-428`) — confirmed step 10 satisfies this.
    - Per-user flood guard: ≤5 messages / 15s (`messages_controller.rb:62-67`).
    - `rescue_and_log(target: message, parent: @contest)` on save (`messages_controller.rb:24-27`).
    - `Message#after_create_commit :broadcast_new_message` (`app/models/message.rb:17, 43-52`) → Turbo `broadcast_prepend_to([contest, :messages], target: "contest_#{contest_id}_messages", partial: "messages/message")`.
    - Subscription side: `app/views/contests/_chat_panel.html.erb:41` declares `<%= turbo_stream_from contest, :messages %>` — every browser viewing the contest receives the prepend over ActionCable. No custom channel; only `app/channels/application_cable/{connection,channel}.rb` exist.

## Data touched

- `users` (insert) — `email`, `email_verified_at`, `username`, `web2_solana_address`, `encrypted_web2_solana_private_key`, `session_token`, optionally `reference`.
- `magic_links` (insert + consume) — one-time email sign-in token.
- `stripe_purchases` (insert + update) — `stripe_session_id`, `quantity`, `price_cents`, `status` (pending → minted), `mint_tx_signatures`, `minted_at`.
- `transaction_logs` (insert) — one row for the token purchase (`token_purchase_job.rb:83-91`), one for the entry fee debit (`entry.rb:101-103`).
- `entries` (insert + update) — created `status: :cart` by `toggle_selection`, flipped to `:active` with `onchain_tx_signature` + `onchain_entry_id` by `confirm!` (`entry.rb:104`).
- `selections` (insert × 6) — one per matchup tap (`entry.rb:29-50`).
- `messages` (insert) — `body`, `user_id`, `contest_id`.
- **on-chain**: `UserAccount` PDA (created by `CreateOnchainUserAccountJob` post-signup); one `EntryTokenAccount` PDA per mint (`mint_entry_token` instruction, source = `:stripe`); `Entry` PDA created and the token PDA consumed atomically by `enter_contest_with_token` (turf-vault v0.12.0+).
- **external**: magic-link email; Stripe Checkout Session (created in step 6, validated in step 7); Stripe `checkout.session.completed` webhook; Solana RPC (`sendTransaction` for each mint + the entry).
- **audit**: `OutboundRequest` rows for every Stripe + Solana RPC call (`Current.outbound_source = purchase` at `token_purchase_job.rb:49-50`).

## Failure modes

- **`SeasonConfig.current_season_id == 0` at entry time** — `contests_controller.rb:297` raises `"No active season configured. Set one at /admin/seasons before users can enter on-chain contests."`. User sees toast; operator fix is `/admin/seasons` → set current.
- **No open contest** — `world_cup` returns `redirect_to contests_path` (`contests_controller.rb:218`); user lands on the contest index instead of a show page.
- **Stripe webhook signature mismatch / bad JSON** — `head :bad_request` (`stripe_controller.rb:14-21`). No `StripePurchase` row, no mint; Stripe retries the delivery on its own schedule. Watch the `[tokens] webhook.bad_signature` log.
- **Test-mode event in production** — `head :ok` + warning log (`stripe_controller.rb:29-32`); silently swallowed by design (OPSEC-033).
- **`TokenPurchaseJob` crashes mid-mint** — already-persisted signatures in `stripe_purchases.mint_tx_signatures` set the resume offset on retry (`token_purchase_job.rb:54-66`). Sidekiq retries with the same `stripe_session_id`. Operator watches `/admin/jobs` for stuck Retries and Sentry for `class=...` rescue logs at `token_purchase_job.rb:93-100`.
- **Post-mint step raises (e.g. `TransactionLog.record!` DB hiccup)** — `mark_failed_unless_minted!` refuses to downgrade a minted row (H8 audit; `app/models/concerns/mintable_purchase.rb:36-40`) so the audit stays accurate; job re-raises and Sidekiq retries the TX log write.
- **Contest is full at `enter`** — `with_lock` recount raises `"Contest is full"` (`contests_controller.rb:289-290`); the JSON 422 response surfaces via the board toast.
- **Wallet has no unconsumed entry token at `enter`** — `contests_controller.rb:316` raises `"No entry tokens. Buy at /tokens/buy"`; client surfaces a CTA.
- **Lock time passed mid-build** — `entry.confirm!` raises `"Contest has locked — entries closed"` (H7 audit; `entry.rb:70-72`).
- **Duplicate selection combo** — `entry.confirm!` raises `"You already have an entry with this exact selection combination"` inside the user lock (`entry.rb:85-90`).
- **Chat message too long / blank / hit cooldown** — 422 / 429 from `messages_controller.rb:14-22` and `messages_controller.rb:62-67`; no broadcast.
- **`broadcast_new_message` cable/Redis hiccup** — `rescue` writes to `ErrorLog` (`message.rb:50-52`); the DB row stays, the prepend is silently lost. Reload of the page rebuilds from `Message.recent_for` (`message.rb:22-28`).

## Related workflows

- [[referral-google-tokens-to-chat]] — converges on the same code from step 6 onward (`TokensController#stripe_checkout`, the webhook, `ContestsController#enter`, `MessagesController#create`). Differs at the signup spine: Google OAuth via `OmniauthCallbacksController#create` and the `?reference=` funnel attribution sets `users.invited_by_id`.
- [[web3-landing-to-entry]] — alternate top-of-funnel where the visitor connects Phantom on a landing page; converges on `ContestsController#enter`'s **on-chain wallet** branch (`contests_controller.rb:269-281, 336-346`) instead of the managed-token branch this flow exercises.
- [[admin-contest-setup]] — predecessor flow; produces the `Contest` (and the `SeasonConfig.main_contest` pointer this flow reads at `contests_controller.rb:215`).
