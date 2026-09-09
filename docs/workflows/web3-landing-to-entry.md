# Workflow: Web3 — landing page to on-chain contest entry

> **Code is law.** Every claim below cites `path/to/file.rb:NN` from the current
> codebase. A bare `:NN` inherits the file of the nearest preceding
> path-qualified citation, so any citation that changes file re-states the path.
> `test/docs/workflow_citation_docs_test.rb` enforces both rules, and checks that
> each number still lands inside the symbol its prose names — the symbol is the
> claim, the number is bookkeeping. Cross-repo references name a file and a
> symbol and carry no line number, because a gem bump would rot one.

**Trigger:** `GET /lp/:slug` (a marketing funnel page) — typically reached from a
paid ad, an X/Twitter post, or a friend's share link with `?reference=…`.
Links already in the wild still land: `/l/:token` now belongs to `Studio::Link`,
and an unmatched token falls back to `/lp` (`config/routes.rb:137-139`).
**Actors:** Guest visitor → User (created mid-flow) · Phantom wallet · Rails ·
Sidekiq · Solana devnet/mainnet RPC.
**Outcome:** New `User` row with `web3_solana_address` set, a server-managed
wallet (`web2_solana_address`) attached, an on-chain `UserAccount` PDA
created with username, and an `active` `Entry` row whose `onchain_tx_signature`
points at the `enter_contest` instruction confirmed on-chain.
**Preconditions:** A `LandingPage` row is `active: true` with a `contest_id`
wired — the validation is `contest_required_when_active`
(`app/models/landing_page.rb:52-56`) — and that `Contest` is `open` and on-chain.
Phantom must be installed in the browser or available via mobile deep link.

## Sequence

1. **Land on funnel.** `GET /lp/:slug` → `LandingPagesController#show` —
   `app/controllers/landing_pages_controller.rb:7-21`.
   - Auth is skipped — `skip_before_action :require_authentication` and
     `:require_profile_completion` (`:2-3`) — because funnels are public.
   - A missing or inactive page redirects to root with an alert, unless an
     admin is previewing it (`:11-13`).
   - First-touch attribution: `show` writes `cookies[:reference]` with this
     funnel's slug and a 30-day expiry, and only when the cookie is blank
     (`:18`). So an explicit `?reference=…` captured earlier by
     `ApplicationController#capture_reference`
     (`app/controllers/application_controller.rb:443-448`) wins.
   - Hero CTA renders `link_to @landing_page.cta_label_display,
     contest_path(@contest.slug, scroll: 280)` with `target: "_blank"`
     (`app/views/landing_pages/show.html.erb:65-67`).
   - The `scroll=280` param drives a `window.scrollTo` past the hero chrome to
     the matchup board (`app/views/contests/show.html.erb:224-237`).
   - Route: `get "lp/:slug", to: "landing_pages#show", as: :landing_page` —
     `config/routes.rb:139`.

2. **Land on contest.** The new tab opens `GET /contests/:slug?scroll=280` →
   `ContestsController#show` — `app/controllers/contests_controller.rb:574-615`.
   - `:show` sits in the `skip_before_action :require_authentication` list
     (`:9`), so guests render.
   - `set_contest` (`:2588-2615`) loads the contest by slug and hides `pending`
     rows from non-admins (`:2589-2590`). On a miss it logs a forensic
     `[set_contest:miss]` warning — slug, path, referer, turbo-frame, user
     agent — for the recurring "Contest not found" toast (`:2598-2609`).
   - `render "contests/hero"` (`app/views/contests/show.html.erb:14`) and
     `render "contests/contest_header"` (`:17`) are unconditional. Only the
     matchup board is gated: contest `open?`, not cancelled, and the viewer
     holding no entry — unless `show_board_for_existing_entry` opens it back
     up for `?add_entry=true` (`:59`).
   - The board partial mounts `x-data="selectionBoard()"` —
     `app/views/contests/_turf_totals_board.html.erb:2049`. The factory is
     defined inline as `window.selectionBoard = function()` (`:159`) because
     Alpine processes `x-data` before importmap modules load (see
     `docs/UI_PATTERNS.md` § Alpine + ERB Constraints).
   - Board config — picks_required, matchup data, contest slug, cart state — is
     serialized into the `board-config` JSON block (`:72-154`) and read once by
     the factory (`:160-161`). Auth state is never copied there: the `loggedIn`
     getter reads `Alpine.store('session')` live on every access (`:185`).

3. **Build cart (no auth required).** Guest taps matchup cards. Each tap calls
   `selectionBoard.toggleSelection(matchupId)` —
   `_turf_totals_board.html.erb:652-730`.
   - Hard-capped at `contest.picks_required` (6 for Turf Totals). A tap past the
     cap replaces the oldest pick rather than refusing (`:676-686`).
   - A guest's tap only mutates local Alpine state — the method returns before
     the network call (`:693`).
   - When logged in it POSTs `/contests/:id/toggle_selection` (`:695-702`) →
     `ContestsController#toggle_selection`
     (`app/controllers/contests_controller.rb:1424-1445`), which finds or
     creates the user's `:cart` entry (`:1432`) and toggles a `Selection`
     through `Entry#toggle_selection!` (`app/models/entry.rb:43-68`).
   - The server's selection set is authoritative; the client adopts it rather
     than trusting its own optimistic mutation
     (`_turf_totals_board.html.erb:729`).
   - At `picks_required` selections the board blurs behind the cart —
     `blurDismissed` gates the overlay (`:2060-2066`) — and the shared
     `render 'studio/hold_button'` appears (`:2239`).

4. **Hold-to-Confirm fires.** The shared hold button dispatches the
   `hold-confirm-entry` window event; the board's `init()` listener routes it
   into `confirmEntry()` (`_turf_totals_board.html.erb:343-350`).
   - `runHoldValidations()` (`:1507-1537`) hits `GET /geo/check` first
     (`:1509`); a blocked state aborts into the `Location Restricted` redirect
     modal (`:1513`). That route is drawn by the engine now, behind
     `config.draw_geo_routes`, not by this app (`config/routes.rb:602-608`).
   - `confirmEntry()` (`_turf_totals_board.html.erb:1554-1963`) short-circuits
     to `showLoginModal()` when the session is a guest (`:1563-1567`), which
     opens the auth wizard at `step: 'credentials'` (`:923-936`) — the entry
     into step 5.
   - `Alpine.store('session').isGuest` is the canonical guest pivot, derived
     from `SessionContext#mode` (`studio-engine: app/models/session_context.rb`)
     and hydrated from the `session-context` JSON block on every render
     (`app/views/layouts/application.html.erb:217`).

5. **Sign up via Phantom.** Choosing Solana in that wizard calls
   `openWalletConnect(ageAttested)`
   (`app/views/contests/_turf_totals_board.html.erb:1011-1016`), which swaps in
   solana-studio's wallet picker. The picker runs
   `window.solanaConnectAndVerify` — `app/views/layouts/application.html.erb:299`.
   - The nonce is fetched from `/auth/solana/nonce` (`:335`) →
     `SolanaSessionsController#nonce`
     (`app/controllers/solana_sessions_controller.rb:5-9`).
   - Two signing paths. A wallet that supports SIWS `signIn` is used directly;
     otherwise the message is built locally — domain, pubkey, statement,
     `Nonce:` — and signed with `provider.signMessage`
     (`app/views/layouts/application.html.erb:503-505`).
   - The `User-ID` binding that ties a signature to an account (OPSEC-005) rides
     only on the wallet-LINK path (`opts.linkMode`), not on signup (`:393`).
   - The signature is base58-encoded and POSTed to `/auth/solana/verify`
     (`:683`) as `signatureB58` alongside the message and pubkey (`:715-719`).
     An unreadable answer to that POST — an HTML-bodied 500 of ours — is
     substituted inside `.json()` and named as our server's fault rather than
     mapped into balance advice (closed 2026-09-09; see `docs/AUTH.md`).

6. **Server verifies + creates User.** `SolanaSessionsController#verify` —
   `app/controllers/solana_sessions_controller.rb:25-103`.
   - Signature check: `Solana::SessionAuth#verify_solana_signature!`
     (`studio-engine: app/controllers/concerns/solana/session_auth.rb`) runs
     pure-Ruby ed25519 through `Solana::AuthVerifier.verify!` — nonce
     delete-before-verify, host bind, TTL. **No Solana RPC call** during signup
     (OPSEC-044 — see `docs/SIGNUP_FLOWS.md`). Called at `:26-31`.
   - `User.from_solana_wallet(pubkey_b58)` looks up an existing user
     (`app/models/user.rb:236-238`); if absent, `verify` builds a new `User`
     with `web3_solana_address` and `reference: cookies[:reference]` — the
     first-touch stamp set in step 1
     (`app/controllers/solana_sessions_controller.rb:34`, `:53-57`).
   - `user.save!` triggers the shared spine. Declaration and definition sit far
     apart in `app/models/user.rb`, so both are cited:
     - `before_validation :ensure_username` (`app/models/user.rb:106`) —
       `ensure_username` auto-fills a username via
       `Studio::UsernameGenerator.generate` (`:728-743`).
     - `before_create :set_initial_session_token` (`:108`) — writes
       `users.session_token` for OPSEC-045 cookie binding (`:527-529`).
     - `after_create :generate_managed_wallet!` (`:123`) — generates a
       server-managed ed25519 keypair with `Solana::Keypair.generate` (`:573`,
       local, no RPC), encrypts the secret key (`:576`), and writes
       `web2_solana_address` + `encrypted_web2_solana_private_key`. It bails for
       admins (`:572`) and, under `AppFlags.web3_only_onboarding?`, for everyone
       (`:566`). The key material itself is read a layer down, in
       `Solana::Keypair.current_encryptor`
       (`app/services/solana/keypair.rb:117-122`).
     - `after_commit :enqueue_onchain_account_setup`
       (`app/models/user.rb:127`) →
       `CreateOnchainUserAccountJob.perform_later` (`:779-781`). Async — the
       user is logged in before the on-chain PDA finalizes.
   - `cookies.delete(:reference)` consumes the cookie only for a new signup
     (`app/controllers/solana_sessions_controller.rb:62`).
   - `set_app_session(user)` writes `session[:turf_user_id]` +
     `session[:session_token]` and clears any stale on-chain flag
     (`app/controllers/application_controller.rb:33-66`, `:41`).
     `promote_to_onchain_session!` then grants it (`:499-504`) — that write is
     what `onchain_session?` reads (`:478-481`), and `verify` calls it at
     `app/controllers/solana_sessions_controller.rb:77`. It lives in
     `ApplicationController` because the login and wallet-link paths used to
     drift apart.
   - Response: `render json: { success: true, redirect: redirect, new_user:
     is_new }` (`:97`).
   - **The in-board flow does not follow that redirect.** The board's
     `openWalletConnect(ageAttested)` saved the guest lineup before handing off
     to the picker and set `returnUrl` to this contest
     (`_turf_totals_board.html.erb:1011-1016`), so the user lands back on the
     contest page with the cart persisted and replayed by `init()` (`:483-495`).

7. **Background: on-chain UserAccount PDA created.**
   `CreateOnchainUserAccountJob#perform` —
   `app/jobs/create_onchain_user_account_job.rb:10-19`.
   - Skips a user with no wallet (`:12`), then calls
     `Solana::Vault#ensure_user_account` (`:14`).
   - `ensure_user_account` is an idempotent no-op when the PDA already exists —
     the `:ok` status returns `nil` (`app/services/solana/vault.rb:728-737`,
     `:731`) — so Sidekiq retries are safe.
   - The job logs and re-`raise`s so Sidekiq retries
     (`app/jobs/create_onchain_user_account_job.rb:16-18`).
   - This is the FIRST on-chain TX in the whole flow — signup itself is pure
     ed25519. The job runs out-of-band; entry submission below does NOT block on
     it, because the entry path re-asserts `ensure_user_account` synchronously
     (see step 9).

8. **Post-reload: cart hydrates + auto-enter fires.** Board `init()` reads the
   saved lineup out of `localStorage`, discarding one older than 30 minutes or
   belonging to another contest (`_turf_totals_board.html.erb:459-463`).
   - Hydrates `selections` + `selectionOrder` and opens the cart (`:468-472`).
   - When the session is logged in, the lineup asked to auto-enter, and the
     count matches `picksRequired`, `init()` schedules `afterLoginSuccess()`
     (`:474`, `:492-494`). A pending wallet-setup prompt re-saves the cart
     instead, so linking Phantom cannot cost the user their lineup (`:483-485`).
   - `afterLoginSuccess()` (`:1349-1378`) surfaces an eligibility blocker first,
     then replays the picks to the server through `replaySelectionsToServer()`
     (`:1095-1112` — one `toggle_selection` POST per pick) and calls
     `confirmEntry()`.

9. **Web3 entry: prepare + sign + confirm.** `confirmEntry()` branches on
   `sess.isWeb3 && this.contestOnchain`
   (`_turf_totals_board.html.erb:1618`).
   - **Wallet re-assert.** `provider.connect()` runs first, and a `pubkeyB58`
     that does not match the session address aborts before any server call
     (`:1638-1642`).
   - **`POST /contests/:id/prepare_entry`** (`:1664`) →
     `ContestsController#prepare_entry`
     (`app/controllers/contests_controller.rb:952-1099`).
     - Requires `onchain_session?` — a session with no live wallet signature
       gets 403 `"Phantom session required"` (`:975`).
     - Survivor contests are admitted, not refused: they have no pick-building
       phase, so `prepare_entry` mints the cart entry on the spot (`:961-962`).
     - Server validates: the contest is `onchain_verified?` (`:996`), a Phantom
       wallet is present (`:997`), there is capacity (`:999-1000`), the entry
       holds exactly `picks_required` selections (`:1003`), and no picked game
       has started (`:1004-1006`). Then it assigns the entry number
       (`:1015`).
     - `Solana::Vault#ensure_user_account` runs synchronously here (`:1020`),
       closing the race where the async `CreateOnchainUserAccountJob` has not
       landed yet.
     - **Two funding shapes.** Holding an unconsumed entry token builds
       `build_enter_contest_with_token` (`:1033-1045`); otherwise the currency
       is resolved USDC-or-USDT (`:983-993`) and it builds
       `vault.build_enter_contest` (`:1056-1062`,
       `app/services/solana/vault.rb:1300`). Either way the transaction comes
       back FULLY UNSIGNED.
     - Persists a `PendingTransaction` with `tx_type: "enter_contest"`,
       `status: "pending"`, `target: entry` and a metadata blob naming the entry
       PDA and funding shape
       (`app/controllers/contests_controller.rb:1071-1084`). It carries no
       signature yet — nothing has been broadcast. Survives a mid-flight
       refresh; see failure modes below.
     - Returns `{ success, serialized_tx, entry_id, entry_pda, ptx_slug,
       token_funded }` (`:1086-1095`).
   - **Phantom signs FIRST, and the browser does not broadcast.** The client
     deserializes the base64 transaction and calls `provider.signTransaction`
     (`_turf_totals_board.html.erb:1711`), then re-serializes with
     `requireAllSignatures: false` — the admin slot is deliberately still empty
     (`:1716`). Phantom signing an entirely unsigned transaction is what clears
     Phantom's multi-signer "could be malicious" banner.
   - **`POST /contests/:id/confirm_onchain_entry`** with those wire bytes
     (`:1727-1731`) → `ContestsController#confirm_onchain_entry`
     (`app/controllers/contests_controller.rb:1284-1402`). The server owns
     everything from here — it cosigns with `Transaction.cosign_wire`, simulates,
     broadcasts and waits (`:1273-1283`).
     - Re-runs `entry.assert_enterable!` BEFORE anything irreversible (`:1308`).
     - `assert_entry_cosign_safe!` checks the bytes are the transaction the
       server prepared, for this entry and wallet, before adding a signature
       (`:1331-1334`).
     - `Solana::Vault#cosign_and_broadcast_entry` (`:1340`) fills the admin
       slot, runs a `simulate_transaction` pre-flight, then sends and waits for
       confirmation (`app/services/solana/vault.rb:2400-2420`).
     - The `PendingTransaction` is stamped `submitted` with the signature
       (`app/controllers/contests_controller.rb:1352`) — IMMEDIATELY after
       broadcast and BEFORE the verification below. That order is the A1
       double-charge guard: the money has already moved, so a verification that
       raises must leave a PT that CARRIES the signature, or recovery reads it
       as "never broadcast" and lets the user pay a second time.
     - **OPSEC-010 server-side proof.** `verify_and_confirm_onchain_entry!`
       re-derives the entry PDA through `Solana::Vault#entry_pda`
       (`app/services/solana/vault.rb:186-191`) and refuses a client-supplied
       PDA that disagrees
       (`app/controllers/contests_controller.rb:2554-2570`, `:2556-2559`). Then
       `verify_solana_transaction!` (`:2497-2506`) fetches the transaction from
       chain through `Solana::TxVerifier` and asserts the instruction
       discriminator — `enter_contest` or `enter_contest_with_token`, whichever
       was built — was signed by the user's wallet and wrote the derived PDA
       (`:2561-2566`).
     - `entry.confirm_onchain!(tx_signature:, entry_pda:)` (`:2568`) →
       `app/models/entry.rb:242-272`. Inside a `user.with_lock` transaction
       (`:249`) it re-checks `assert_enterable!` (`:250`), refuses an entry with
       no verified signature (`:260-262`), then `update!(status: :active,
       onchain_tx_signature:, onchain_entry_id:)` (`:264-268`).
     - The `PendingTransaction` is stamped `confirmed` once the entry is
       active (`app/controllers/contests_controller.rb:1363`).
     - `post_entry_seeds_payload` (`:2020-2065`) reads
       `Solana::Vault#seeds_for_entry` to mirror the on-chain award (`:2028`)
       and refreshes the total through `sync_balance` (`:2034-2036`).
   - Modal closes; the seeds bar animates; `lobbyUrl` drives the countdown
     redirect back to the contest page
     (`_turf_totals_board.html.erb:1765`).

## Data touched

- `landing_pages` (read in step 1)
- `cookies[:reference]` (write in step 1 — funnel-attribution stamp)
- `contests` (read in steps 2, 3 and 9; the row is locked via `@contest.with_lock`
  in `ContestsController#enter`
  (`app/controllers/contests_controller.rb:821`), not in `#prepare_entry` or
  `#confirm_onchain_entry`)
- `entries` (insert `:cart` in step 3; update to `:active` in step 9 via
  `Entry#confirm_onchain!`)
- `selections` (insert/destroy in step 3)
- `users` (insert in step 6; `web2_solana_address`,
  `encrypted_web2_solana_private_key`, `session_token`, `username`,
  `reference` all populated)
- `pending_transactions` (insert in step 9 `#prepare_entry`; `pending` →
  `submitted` → `confirmed` inside `#confirm_onchain_entry`)
- `session[:turf_user_id]`, `session[:session_token]` (write in step 6), and the
  on-chain flag set by `promote_to_onchain_session!`
  (`app/controllers/application_controller.rb:499-504`)
- on-chain: `UserAccount` PDA (`ensure_user_account` in step 7; re-asserted
  synchronously in step 9 `#prepare_entry`)
- on-chain: `Entry` PDA + `Contest.entry_fees` USDC/USDT credit, or an entry
  token consumed instead — one atomic `enter_contest` or
  `enter_contest_with_token` instruction (step 9)
- external: Solana devnet/mainnet RPC for simulate, broadcast, confirm and
  signature fetch — all SERVER-side now (logged through
  `Solana::ClientLogger` → `outbound_requests`)
- external: Phantom wallet for two interactions — `signMessage` at signup
  (step 5) and `signTransaction` at entry (step 9). There is no separate
  per-entry SIWS prompt: `confirmEntry` records that it was removed as
  defence-in-depth which doubled the prompts without strengthening on-chain
  integrity (`app/views/contests/_turf_totals_board.html.erb:1645-1651`).

## Failure modes

- **`?reference=` cookie collision.** A user who clicks Landing Page A and then
  Landing Page B keeps A's attribution: both `capture_reference` and
  `LandingPagesController#show` only set the cookie when it is blank
  (`app/controllers/landing_pages_controller.rb:18`). Symptom:
  `User.reference` does not match the page that converted them.
- **No on-chain Contest PDA.** Paid contests refuse free entry —
  `ContestsController#enter` raises `"This contest isn't on-chain yet — paid
  entry is unavailable."` (`app/controllers/contests_controller.rb:838-839`).
  `Entry#confirm!` carries the model-level backstop for the same hole, with its
  own wording: `"Entry payment required — no entry token consumed or on-chain
  payment recorded"` (`app/models/entry.rb:185-187`). Always set the contest
  on-chain before publishing the landing page.
- **No active season.** `#enter` raises `"No active season configured. Set one
  at /admin/seasons before users can enter on-chain contests."`
  (`app/controllers/contests_controller.rb:829-831`) — the operator must call
  `SeasonConfig.set_current!(season_id)` first. Caught before the user spends a
  Phantom signature.
- **Wrong wallet connected.** `confirmEntry` re-asserts the connected
  `pubkeyB58` against the session address
  (`app/views/contests/_turf_totals_board.html.erb:1638-1642`) — symptom:
  "Wrong wallet connected. Switch to abcd…". The user must reconnect the wallet
  that owns the account, or switch Phantom's active wallet.
- **Refresh mid-flight (signed, handed to the server, awaiting confirmation).**
  Covered by `PendingTransaction`. On the next page load
  `find_pending_recovery_ptx`
  (`app/controllers/contests_controller.rb:2666-2686`) puts the slug into the
  board config, `init()` calls `recoverPendingEntry()`
  (`app/views/contests/_turf_totals_board.html.erb:518-554`, POST at `:526`),
  and `ContestsController#recover_pending_entry`
  (`app/controllers/contests_controller.rb:1173-1271`) polls the signature once
  (`:1221-1222`): still propagating renders `processing` (`:1224-1226`), an
  on-chain error marks it `failed` (`:1228-1231`), and a landed transaction is
  verified and promoted to `active` (`:1245-1249`). The CLIENT owns the polling
  cadence; the only server-side clock sweeps signature-less rows older than ten
  minutes to `expired` (`:2681-2683`).
- **Refresh between sign and hand-off.** The server never received the bytes, so
  `ptx.tx_signature` is blank — and the recovery modal never opens for it.
  `find_pending_recovery_ptx` returns only signature-carrying rows and sweeps
  the signature-less ones to `expired` after ten minutes (`:2680-2685`), so the
  board config gets no slug and `recoverPendingEntry()` is never called. The
  user is released silently; nothing was broadcast, so nothing is owed. The
  blank-signature branch inside `recover_pending_entry` — `"Your last entry did
  not go through — try again."` (`:1213-1216`) — is defense-in-depth for a
  caller that supplies such a slug directly, not a message this flow produces.
- **OPSEC-010 PDA mismatch.** `verify_and_confirm_onchain_entry!` raises
  `"Entry PDA mismatch"` when the client-supplied `entry_pda` differs from the
  server-derived one (`:2556-2559`). Surfaces as a red Solana modal; the entry
  stays in `:cart` and the user can retry. The recovery path omits the
  client value deliberately and skips that cross-check (`:2518-2523`).
- **Sybil duplicate-combo entry.** `Entry#assert_enterable!` raises `"You
  already have an entry with this exact selection combination"`
  (`app/models/entry.rb:153-158`). The user must change at least one pick.
- **Per-user entry limit.** `Contest#max_entries_per_user` (3 for Turf Totals)
  is enforced by `assert_enterable!` inside the same `user.with_lock`
  (`:150-151`).
- **Start window crossed during signing.** `assert_enterable!` raises
  `"Contest has locked — entries closed"` once `contest.locks_at` has passed
  (`:134-136`), so a stale Phantom prompt cannot squeak through after lock.
  Prelaunch audit H7 fix — closes the staggered-kickoff info-edge attack.
- **`CreateOnchainUserAccountJob` failure.** `#perform` logs and re-`raise`s for
  Sidekiq retry (`app/jobs/create_onchain_user_account_job.rb:16-18`).
  `#prepare_entry`'s synchronous `ensure_user_account`
  (`app/controllers/contests_controller.rb:1020`) covers the case where the job
  has not yet succeeded by entry time.

> **Orphaned endpoint.** `ContestsController#stamp_entry_signature`
> (`app/controllers/contests_controller.rb:1149-1161`, routed as
> `post :stamp_entry_signature` at `config/routes.rb:313`) is no longer called
> by any client. It belonged to the
> browser-broadcast flow, and the comment that replaced it says so —
> `the client no longer calls stamp_entry_signature before confirm`
> (`app/controllers/contests_controller.rb:1282-1283`). Only tests reach it now,
> and its own header comment still describes the retired
> `connection.confirmTransaction` wait (`:1143-1148`).

## Related workflows

- [[admin-contest-setup]] — predecessor: an operator must publish the on-chain
  Contest PDA + active LandingPage before this flow can run.
- [[email-signup-token-to-chat]] — alternate signup lane (web2 / managed
  wallet) starting from the same landing page; diverges at step 5 into
  Stripe token purchase rather than Phantom signing.
- [[referral-google-tokens-to-chat]] — alternate signup lane (Google
  OAuth) sharing the same `cookies[:reference]` first-touch attribution
  set in step 1.
