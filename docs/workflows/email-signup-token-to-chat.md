# Workflow: email magic-link signup → token → chat

> **Code is law.** Every claim below cites `path/to/file.rb:NN` from the current
> codebase, and a bare `:NN` inherits the nearest preceding path — file context
> resets at each `##` heading. The number is bookkeeping; the SYMBOL beside it is
> the claim, and `test/docs/workflow_citation_docs_test.rb` reddens when a
> citation stops landing inside the definition its prose names.
> That symbol check reaches **149 of the 179 citations** here. The other **30**
> sit in code with no enclosing definition the guard can derive: ERB markup in
> the four view partials, six `config/routes.rb` entries, one comment block, the
> `PACKS` constant, and the class-body `before_action` / `skip_before_action` /
> `after_create` / `after_commit` / `include` declarations in
> `app/models/user.rb`, `app/models/message.rb`, `app/models/stripe_purchase.rb`,
> `app/controllers/tokens_controller.rb`,
> `app/controllers/messages_controller.rb`,
> `app/controllers/contests_controller.rb` and
> `app/controllers/webhooks/stripe_controller.rb`. Those ride the weaker LITERAL
> fallback: it proves the words the prose quotes are present in the cited lines,
> not that the code is. Cross-repo `studio-engine:` references carry NO line
> number on purpose — the gem is versioned, so a number in it would rot on an
> unrelated `bundle update`; those name the file and the symbol instead, written
> `Klass#method` even for a singleton method, because that is the shape the
> guard reads the symbol out of.
>
> **Legacy Stripe path.** Stripe checkout is retired by default; this workflow is
> still useful when explicitly reviving `PAYMENT_PROVIDER=stripe` for historical
> compatibility or regression testing. Re-confirm whether PayPal, CDP, or direct
> USDC entry is now the intended flow before using this as live product context.

**Trigger:** Anonymous visitor opens `/` (`GET /`)
**Actors:** User / Rails / email transport / Stripe / Sidekiq / Solana RPC (devnet)
**Outcome:** New `users` row, server-managed wallet generated, on-chain `UserAccount` PDA created, one Stripe-funded on-chain `EntryTokenAccount` minted and consumed, an `entries` row for the main contest in status `active` with 6 `selections`, and one visible `messages` row broadcast over ActionCable to that contest's chat stream.
**Preconditions:** at least one contest in status `open`/`settled` exists, or `Contest.featured` returns nil and root falls back to `/contests` (`app/models/contest.rb:200-205`; `locked` is no longer a status — it is a derived time-gate). `PAYMENT_PROVIDER=stripe` plus Stripe keys set (`Rails.application.config.x.stripe_enabled`, checked in `TokensController#stripe_checkout` at `app/controllers/tokens_controller.rb:29-31`). A `SeasonConfig` row with a non-zero `current_season_id`, enforced on the entry path by `ContestsController#ensure_onchain_season_ready!` (`app/controllers/contests_controller.rb:2443-2447`). The chosen contest must be on-chain — the token branch of `ContestsController#resolve_web2_entry_funding!` is what consumes the `EntryTokenAccount` (`:1894-1906`).

## Sequence

1. **Visitor lands on `/`** — `root "contests#world_cup"` (`config/routes.rb:57`) → `ContestsController#world_cup` (`app/controllers/contests_controller.rb:617-621`).
   - `world_cup` is in the `skip_before_action :require_authentication` list, so logged-out browsing works (`app/controllers/contests_controller.rb:9`).
   - It picks the contest with `Contest.featured` (`app/models/contest.rb:200-205`), whose chain is `SeasonConfig.main_contest_explicit` → most recent `open` non-`coming_soon` → most recent `open`/`settled` non-`coming_soon`. It does NOT call `SeasonConfig.main_contest` (`app/models/season_config.rb:33-37`); that resolver is a separate one used by the share widget and faucet CTA, and it applies a different fallback.
   - `world_cup` then 302s to `contest_path(@contest)` (`app/controllers/contests_controller.rb:620`).

2. **Show page renders for a logged-out visitor** — `ContestsController#show` (`app/controllers/contests_controller.rb:623-664`) → `app/views/contests/show.html.erb`.
   - Hero banner + creator avatar + on-chain explorer link — `contests/hero` is rendered at `app/views/contests/show.html.erb:26`; inside the partial the `explorer.solana.com` link is at `app/views/contests/_hero.html.erb:19` and the avatar circle, which renders `creator_name.first.upcase`, at `:29-31`.
   - The inline matchup board never links out to `/tokens/buy`: the buy affordance is the IN-MODAL entry-token picker opened by `showBuyEntryToken()` (`app/views/contests/_turf_totals_board.html.erb:1243-1261`), so the buyer never visually leaves the contest. An anonymous visitor is bounced to the auth modal first — `confirmEntry()` reads `sess.isGuest` and calls `showLoginModal()` (`:1574-1579`) — and resumed afterwards by `afterLoginSuccess()` (`:1361-1390`), which replays the cart and re-runs `confirmEntry`. From there `showEligibilityBlockerModal()` (`:811-836`) routes a token-less buyer onward. The entry fee reaches the board as `entryFeeCents` (`:142`).

3. **Clicks "Sign in" in the navbar** — the logged-out CTA targets the unified `/signin` page, `get "signin", to: "sessions#new"` (`config/routes.rb:172`). Legacy `GET /login` and `GET /signup` both redirect through `signin_redirect` (`:174-175`).

4. **Requests an email magic link** — `SessionsController#new` (`app/controllers/sessions_controller.rb:15-16`) renders the unified auth surface; the email form posts to `POST /magic_link`, routed to `magic_links#create` (`config/routes.rb:228`).
   - `MagicLinksController#create` (`app/controllers/magic_links_controller.rb:37-51`) checks the email shape with `User.valid_email?` at `:39`, mints the one-time link through `Studio::Link#create_magic_link` (`studio-engine: app/models/studio/link.rb`) at `:43-44`, and delivers `UserMailer.magic_link` through `Studio::Email` at `:45`.
   - The response is uniform for every well-formed request (`:47-50`), so the endpoint does not enumerate accounts.

5. **Consumes the magic link** — the emailed URL first hits the INERT `GET /magic_link/:token`, routed to `magic_links#confirm` (`config/routes.rb:229`); the human confirmation form then POSTs to `POST /magic_link/:token`, routed to `magic_links#consume` (`:231`).
   - `MagicLinksController#confirm` (`app/controllers/magic_links_controller.rb:68-85`) never burns the token: it previews the link and renders the confirmation only while the link is still live (`:84`).
   - `MagicLinksController#consume` (`:95-98`) is the only place the token is burned, through `Studio::LinkConsumption#consume_magic_link` (`studio-engine: app/controllers/concerns/studio/link_consumption.rb`) at `:97`. Winning the atomic burn IS the proof the link was live.
   - If the user does not exist, `MagicLinksController#sign_up_new` (`:166-241`) builds `User.new(email: result.email, …)` at `:177-179` and saves at `:182`.
   - `user.save!` triggers the shared spine on `User` (see [[referral-google-tokens-to-chat]] for the equivalent flow on the Google path):
     - `before_validation :ensure_username, on: :create` (`app/models/user.rb:106`) runs `User#ensure_username` (`:742-757`), which fills `username` from `Studio::UsernameGenerator.generate` (`:754-756`).
     - `before_create :set_initial_session_token` (`:108`) runs `User#set_initial_session_token` (`:527-529`), writing `users.session_token` for the OPSEC-045 cookie binding.
     - `after_create :generate_managed_wallet!` (`:123`) runs `User#generate_managed_wallet!` (`:571-599`): `Solana::Keypair.generate` (local ed25519, **no RPC**) at `:587`, then the encrypted keypair is written to `web2_solana_address` + `encrypted_web2_solana_private_key` at `:588-591`. It early-returns for admins (`:586`, OPSEC-044) and for every signup while `AppFlags.web3_only_onboarding?` is on (`:580`).
     - `after_commit :enqueue_onchain_account_setup, on: :create` (`:127`) runs `User#enqueue_onchain_account_setup` (`:793-795`), which enqueues `CreateOnchainUserAccountJob`. Async — the user is logged in before the PDA settles.
   - `set_app_session(user)` at `app/controllers/magic_links_controller.rb:185` writes `session[:turf_user_id]` and `session[:session_token]` and clears any stale `session[:onchain]` (`app/controllers/application_controller.rb:33-47`).
   - Consuming the link proves email ownership, so `email_verified_at` is stamped at `app/controllers/magic_links_controller.rb:184`.

6. **Buy 1 token via Stripe** — `TokensController#buy` (`app/controllers/tokens_controller.rb:7-16`) renders `app/views/tokens/buy.html.erb` with `StripePurchase.available_packs` (`:8`).
   - Pack catalog: the frozen `PACKS` constant (`app/models/stripe_purchase.rb:15-22`) — `"single"` is 1 token at `19_00` cents, the `"trio"` bundle is 3 at `49_00`, and both share one checkout path with a different `pack_id`. `"test_trio"` ($5) is hidden unless `AppFlags.test_scaffolding?` is on, which is what `StripePurchase.available_packs` decides (`:41-43`).
   - The pack button form POSTs `/tokens/stripe_checkout?pack=single` → `TokensController#stripe_checkout` (`app/controllers/tokens_controller.rb:18-96`).
   - Gates before it: the class-body `before_action :require_login` (`:2`, definition `TokensController#require_login` at `:526-537`) and `before_action :require_unfrozen_account` (`:5`, OPSEC-048). Gates inside `stripe_checkout`: an unknown or unavailable pack (`:20-22`), `current_user.solana_connected?` (`:23-25`), the `stripe_enabled` boot flag (`:29-31`), `Payments.stripe?` as the active provider (`:32-34`), and the `payment_risk_flag` chargeback block (`:37-39`, OPSEC-036).
   - The Stripe call is wrapped in `rescue_and_log(target: current_user)` (`:48`). `stripe_checkout` builds a `Stripe::Checkout::Session` whose `metadata.kind` is `"tokens"` and whose `metadata.wallet_address` is `current_user.solana_address` (`:64-71`), with a `success_url` of `tokens_processing_url?session_id={CHECKOUT_SESSION_ID}` (`:60-62`), and creates it at `:78`. A same-tab HTML submit 302s to Stripe (`:82`); the in-modal fetch gets `{ url: session.url }` instead (`:88`).

7. **Stripe webhook credits the token on-chain** — `POST /webhooks/stripe` → `Webhooks::StripeController#create` (`app/controllers/webhooks/stripe_controller.rb:8-62`).
   - The class-body `skip_before_action` block skips `:verify_authenticity_token`, `:require_authentication`, `:detect_geo_state` and `:require_profile_completion` (`:3-6`).
   - `Stripe::Webhook.construct_event` verifies the signature (`:14`); OPSEC-033 rejects test-mode events in production (`:29-32`).
   - The `case event.type` dispatch routes `checkout.session.completed` to `Webhooks::StripeController#handle_checkout_completed` (`:34-35`, definition `:66-108`).
     - `StripeCheckoutValidator.new(stripe_session_id, kind: "tokens").call` re-fetches the session and validates `payment_status` / `livemode` / `kind` / `amount` (`:75`).
     - `TokenPurchaseJob.perform_later(...)` enqueues only after that (`:89-95`).
   - `TokenPurchaseJob#perform` (`app/jobs/token_purchase_job.rb:36-169`):
     - `Solana::Vault.ensure_program_id_live!` catches a stale Sidekiq `PROGRAM_ID` before any mint (`:56`).
     - Terminal short-circuit: a purchase already `minted` or `refunded` returns without minting (`:70-73`) — the OPSEC-009 idempotency stop.
     - Find-or-create the `StripePurchase` row (`:95-101`).
     - `Solana::Vault#mint_entry_token` runs once per pack quantity (`:123-135`), with `source_ref` built as `"#{purchase_type}:#{purchase.id}:#{i}"` (`:124`) — the PURCHASE row id, NOT the Stripe session id.
     - Each successful signature is persisted to `purchase.mint_tx_signatures` **inside the loop** (`:133`); partial-failure resume reads it back as `already_minted` (`:115-117`).
     - `purchase.mark_minted!(signatures)` (`:138`) then `TransactionLog.record!` writes the audit row (`:151-159`).
     - The rescue calls `purchase&.mark_failed_unless_minted!` (`:167`, definition `app/models/concerns/mintable_purchase.rb:36-40`, mixed into `StripePurchase` by the `include MintablePurchase` at `app/models/stripe_purchase.rb:7`) and re-raises so Sidekiq retries.
   - The browser polls `/tokens/status` from the processing page until the purchase reads `minted`; the endpoint is `TokensController#status` (`app/controllers/tokens_controller.rb:446-488`).

8. **Back to root → main contest** — the user clicks the navbar "Turf Monster" home link → `GET /` → step 1 repeats → 302 to `contest_path(@contest)`.
   - Same `ContestsController#world_cup` action, same `Contest.featured` chain (`app/controllers/contests_controller.rb:618`).
   - "Main contest" surfacing is the admin's explicit pick from `/admin/site_config`, stored by `SeasonConfig.set_main_contest!` (`app/models/season_config.rb:45-48`) and read back by `SeasonConfig.main_contest_explicit` (`:41-43`). After that the fallback is most-recent `open`, then most-recent `open`/`settled` (`app/models/contest.rb:202-204`). **No** highest-pot ordering.

9. **Build a 6-pick lineup** — each tap on a matchup tile POSTs to `ContestsController#toggle_selection` (`app/controllers/contests_controller.rb:1481-1502`).
   - It rejects the tap unless the contest is `open?` (`:1482-1484`).
   - `find_or_create_by!(user: current_user, status: :cart)` creates the cart `Entry` on the first toggle (`:1489`).
   - `entry.toggle_selection!(matchup)` (`:1492`) enforces the cap of `contest.picks_required` — 6 — inside `Entry#toggle_selection!` (`app/models/entry.rb:43-68`), which replaces the oldest pick once the cap is reached (`:53-59`).
   - The body is wrapped in `rescue_and_log(target: entry, parent: @contest)` (`app/controllers/contests_controller.rb:1491`).

10. **Hold-to-Confirm fires `POST /contests/:id/enter`** — `ContestsController#enter` (`app/controllers/contests_controller.rb:716-938`).
    - Gated by the class-body `before_action :require_geo_allowed` (`:16`) and `before_action :require_unfrozen_account` (`:18`).
    - `enter` loads the cart entry at `:753`, and the web2 / managed-wallet funding branch runs inside its `@contest.with_lock` (`:870`) through `ContestsController#resolve_web2_entry_funding!` (`:1878-1950`, documented at `:1858-1869`):
      - `current_user.next_unconsumed_entry_token_for(address)` reads the token on-chain (`:1894`, definition `User#next_unconsumed_entry_token_for` at `app/models/user.rb:729-736`). With no token and no USDC the branch raises `"No entry tokens. Buy at /tokens/buy"` (`app/controllers/contests_controller.rb:1948`).
      - `Solana::Vault#enter_contest_with_token` is the atomic Anchor instruction — it creates the entry PDA, consumes the token, and awards seeds (`:1898-1901`, definition `app/services/solana/vault.rb:1369`). The managed wallet's keypair, decrypted from the DB by `User#solana_keypair` (`app/models/user.rb:552-555`), signs it.
    - `entry.confirm!(tx_signature:, onchain_entry_id:)` runs from `ContestsController#finalize_managed_entry!` (`app/controllers/contests_controller.rb:2050`). `Entry#confirm!` (`app/models/entry.rb:170-208`) re-runs `assert_enterable!` under the user row lock (`:176`), refuses a paid entry with no payment proof (`:185-187`), writes the `entry_fee` `TransactionLog` debit (`:189-191`), and flips `entries.status` → `active` (`:192`). The 6-selection count, lock time, and duplicate-combo checks all live in `Entry#assert_enterable!` (`:125-159`).
    - The JSON response carries `redirect: contest_path(@contest)` (`app/controllers/contests_controller.rb:925`).

11. **Land back on the contest show page** — `@has_entry` is now true, so the seeds + share cards render (`app/views/contests/show.html.erb:34-57`) and the leaderboard partial replaces the matchup board. The same page hosts `contests/chat_panel`, rendered at `:103`.

12. **Send a chat message** — the composer in the chat panel POSTs to `contest_messages_path(contest)` (`app/views/contests/_chat_panel.html.erb:38`) from `send()` (`:220-264`) → `MessagesController#create` (`app/controllers/messages_controller.rb:8-33`).
    - The class-body `before_action :set_contest` (`:4`, definition `MessagesController#set_contest` at `:130-133`) and `before_action :require_chat_enabled` (`:5`, definition `MessagesController#require_chat_enabled` at `:135-138`, which reads the `chat_enabled` DB column).
    - `@contest.chat_participant?(current_user)` at `:9` requires `admin?` or an `active`/`complete` entry (`app/models/contest.rb:803-807`) — step 10 satisfies it.
    - Per-user flood guard: at most 5 messages per 15 seconds in `MessagesController#posting_too_fast?` (`app/controllers/messages_controller.rb:142-147`), checked at `:13-15`.
    - The save is wrapped in `rescue_and_log(target: message, parent: @contest)` (`:24-30`).
    - The `after_create_commit :broadcast_new_message` declaration (`app/models/message.rb:61`) runs `Message#broadcast_new_message` (`:87-96`), which calls Turbo's `broadcast_prepend_to([contest, :messages], target: "contest_#{contest_id}_messages", partial: "messages/message")` at `:88-93`.
    - Subscription side: `turbo_stream_from` at `app/views/contests/_chat_panel.html.erb:41` — every browser viewing the contest receives the prepend over ActionCable. No custom channel; only `app/channels/application_cable/{connection,channel}.rb` exist.

## Data touched

- `users` (insert) — `email`, `email_verified_at`, `username`, `web2_solana_address`, `encrypted_web2_solana_private_key`, `session_token`, optionally `reference` — all set by `MagicLinksController#sign_up_new` (`app/controllers/magic_links_controller.rb:177-179`).
- `magic_links` (insert + consume) — the one-time email sign-in row, owned by the gem: `Studio::Link#create_magic_link` (`studio-engine: app/models/studio/link.rb`).
- `stripe_purchases` (insert + update) — `stripe_session_id`, `quantity`, `price_cents`, `status` (pending → minted), `mint_tx_signatures`, `minted_at`; the row is created by `TokenPurchaseJob#perform` (`app/jobs/token_purchase_job.rb:95-101`).
- `transaction_logs` (insert) — one row for the token purchase from `TokenPurchaseJob#perform` (`app/jobs/token_purchase_job.rb:151-159`), one for the entry-fee debit from `Entry#confirm!` (`app/models/entry.rb:189-191`).
- `entries` (insert + update) — created `status: :cart` by `ContestsController#toggle_selection` (`app/controllers/contests_controller.rb:1489`), flipped to `:active` with `onchain_tx_signature` + `onchain_entry_id` by `Entry#confirm!` (`app/models/entry.rb:192`).
- `selections` (insert × 6) — one per matchup tap, created inside `Entry#toggle_selection!` (`app/models/entry.rb:54`).
- `messages` (insert) — `body`, `user_id`, `contest_id`, built in `MessagesController#create` (`app/controllers/messages_controller.rb:17`).
- **on-chain**: `UserAccount` PDA (created by `CreateOnchainUserAccountJob` post-signup); one `EntryTokenAccount` PDA per mint through `Solana::Vault#mint_entry_token` (`app/services/solana/vault.rb:1735`, `source: :stripe`); the entry PDA created and the token PDA consumed atomically by `Solana::Vault#enter_contest_with_token` (`:1369`, turf-vault v0.12.0+).
- **external**: magic-link email; Stripe Checkout Session (created in step 6, validated in step 7); the `checkout.session.completed` webhook; Solana RPC (`sendTransaction` for each mint and for the entry).
- **audit**: `OutboundRequest` rows for every Stripe + Solana RPC call — `TokenPurchaseJob#perform` sets `Current.outbound_source = purchase` first (`app/jobs/token_purchase_job.rb:107-108`).

## Failure modes

- **`SeasonConfig.current_season_id == 0` at entry time** — `ContestsController#onchain_season_error` returns `"No active season configured. Set one at /admin/seasons before creating on-chain contests."` (`app/controllers/contests_controller.rb:2449-2451`) and `#ensure_onchain_season_ready!` raises it (`:2443-2447`). The user sees a toast; the operator fix is `/admin/seasons` → set current.
- **No open contest** — `ContestsController#world_cup` returns `redirect_to contests_path` (`app/controllers/contests_controller.rb:619`); the user lands on the contest index instead of a show page.
- **Stripe webhook signature mismatch / bad JSON** — `Webhooks::StripeController#create` returns `head :bad_request` (`app/controllers/webhooks/stripe_controller.rb:15-20`). No `StripePurchase` row, no mint; Stripe retries the delivery on its own schedule. Watch for the `[tokens] webhook.bad_signature` log line.
- **Test-mode event in production** — `Webhooks::StripeController#create` returns `head :ok` plus a warning log (`app/controllers/webhooks/stripe_controller.rb:29-32`); swallowed by design (OPSEC-033).
- **`TokenPurchaseJob` crashes mid-mint** — the signatures already persisted to `stripe_purchases.mint_tx_signatures` set the resume offset on retry: `TokenPurchaseJob#perform` reads them back as `already_minted` (`app/jobs/token_purchase_job.rb:115-117`) and restarts the loop at that index (`:123`). Sidekiq retries with the same `stripe_session_id`. The operator watches `/admin/jobs` for stuck retries and the rescue's log lines (`:161-168`).
- **Post-mint step raises (e.g. a `TransactionLog.record!` DB hiccup)** — `MintablePurchase#mark_failed_unless_minted!` refuses to downgrade a minted row (H8 audit; `app/models/concerns/mintable_purchase.rb:36-40`), so the audit stays accurate; `TokenPurchaseJob#perform` re-raises (`app/jobs/token_purchase_job.rb:168`) and Sidekiq retries the log write.
- **Contest is full at `enter`** — `Entry#assert_enterable!` raises `"Contest is full"` (`app/models/entry.rb:146-147`), run as the pre-flight inside `ContestsController#enter`'s `with_lock` (`app/controllers/contests_controller.rb:873`) so the token is never consumed. The JSON 422 surfaces via the board toast.
- **Wallet has no unconsumed entry token at `enter`** — `ContestsController#resolve_web2_entry_funding!` raises `"No entry tokens. Buy at /tokens/buy"` (`app/controllers/contests_controller.rb:1948`); the client surfaces a CTA.
- **Lock time passed mid-build** — `Entry#assert_enterable!` raises `"Contest has locked — entries closed"` (H7 audit; `app/models/entry.rb:134-136`), and `Entry#toggle_selection!` raises the same message on the pick itself (`:47`).
- **Duplicate selection combo** — `Entry#assert_enterable!` raises `"You already have an entry with this exact selection combination"` (`app/models/entry.rb:153-158`), re-run under the user row lock by `Entry#confirm!` (`:176`).
- **Chat message too long / blank / hit cooldown** — `MessagesController#create` returns 422 for an invalid body (`app/controllers/messages_controller.rb:20-22`) and 429 when `MessagesController#posting_too_fast?` is true (`:142-147`); no broadcast either way.
- **`broadcast_new_message` cable/Redis hiccup** — `Message#broadcast_new_message` rescues into `ErrorLog` (`app/models/message.rb:94-95`); the DB row stays and the prepend is silently lost. A page reload rebuilds the panel from `Message.recent_for` (`:66-72`).

## Related workflows

- [[referral-google-tokens-to-chat]] — converges on the same code from step 6 onward (`TokensController#stripe_checkout`, the webhook, `ContestsController#enter`, `MessagesController#create`). It differs at the signup spine: Google OAuth through `OmniauthCallbacksController#create`, with the `?reference=` funnel attribution writing `users.reference`.
- [[web3-landing-to-entry]] — an alternate top-of-funnel where the visitor connects Phantom on a landing page; it converges on `ContestsController#prepare_entry` (`app/controllers/contests_controller.rb:1001-1156`) and `#confirm_onchain_entry` (`:1341-1459`) instead of the managed-token branch this flow exercises.
- [[admin-contest-setup]] — the predecessor flow; it produces the `Contest` and the `SeasonConfig.main_contest_explicit` pointer `Contest.featured` reads first (`app/models/contest.rb:201`).
