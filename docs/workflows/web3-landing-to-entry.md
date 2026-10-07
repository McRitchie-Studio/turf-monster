# Workflow: Web3 — landing page to on-chain contest entry

> **Code is law.** Every claim below cites `path/to/file.rb:NN` from the current
> codebase. A bare `:NN` inherits the file of the nearest preceding
> path-qualified citation, so any citation that changes file re-states the path.
> `test/docs/workflow_citation_docs_test.rb` enforces both rules and checks every
> number against the symbol its prose names — the symbol is the claim, the number
> is bookkeeping. That check comes in three strengths, and it is worth knowing
> which one you are reading. **129 of the 166 citations** below sit inside a
> definition, and there the prose must name that definition or the citation
> reddens. The other **37** sit in code with no enclosing definition, and they
> split. **4 of those 37** cite `config/routes.rb`, and each must OPEN on the line
> that carries its route — or, where it cites a routes comment, name that whole
> comment block. That catches most one-line drift, not all of it —
> [the workflows README](README.md) has the measurement. For the rest — ERB
> markup, a callback in a class body — the guard asks only that a code token
> quoted nearby appear in the cited lines, which proves the words are present,
> not that the code is. **All 7 citations on
> `app/views/layouts/application.html.erb`** are on that weaker branch, and they
> are the whole Phantom connect-and-sign surface: the file writes its functions
> as `window.solanaConnectAndVerify = async function(…)`, which the guard does
> not read as a definition. Follow one of those seven to the code before you
> trust it. Cross-repo references name a file and a symbol and carry no line
> number, because a gem bump would rot one.

**Trigger:** `GET /lp/:slug` (a marketing funnel page) — typically reached from a
paid ad, an X/Twitter post, or a friend's share link with `?reference=…`.
Links already in the wild still land: `/l/:token` now belongs to `Studio::Link`,
and an unmatched token falls back to `/lp` (`config/routes.rb:146-148`).
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
   `app/controllers/landing_pages_controller.rb:7-20`.
   - Auth is skipped — `skip_before_action :require_authentication` and
     `:require_profile_completion` (`:2-3`) — because funnels are public.
   - A missing or inactive page redirects to root with an alert, unless an
     admin is previewing it (`:10-12`).
   - First-touch attribution: `show` writes `cookies[:reference]` with this
     funnel's slug and a 30-day expiry, and only when the cookie is blank
     (`:17`). So an explicit `?reference=…` captured earlier by
     `ApplicationController#capture_reference`
     (`app/controllers/application_controller.rb:497-502`) wins.
   - Hero CTA renders `link_to @landing_page.cta_label_display,
     contest_path(@contest.slug, scroll: 280)` with `target: "_blank"`
     (`app/views/landing_pages/show.html.erb:79-81`). A claim-mode page
     (`LandingPage#claim_mode`) renders a different CTA that never reaches the
     contest: it goes to `/signin` with `return_to` set to
     `landing_page_claimed_path` (`:73`), the confirmation page. That flow is in
     `docs/UI_PATTERNS.md` under "Claim mode".
   - The `scroll=280` param drives a `window.scrollTo` past the hero chrome to
     the matchup board (`app/views/contests/show.html.erb:213-226`).
   - Route: `get "lp/:slug", to: "landing_pages#show", as: :landing_page` —
     `config/routes.rb:148`.

2. **Land on contest.** The new tab opens `GET /contests/:slug?scroll=280` →
   `ContestsController#show` — `app/controllers/contests_controller.rb:681-688`.
   - `:show` sits in the `skip_before_action :require_authentication` list
     (`:9`), so guests render.
   - `set_contest` (`:2708-2735`) loads the contest by slug and hides `pending`
     rows from non-admins (`:2709-2710`). On a miss it logs a forensic
     `[set_contest:miss]` warning — slug, path, referer, turbo-frame, user
     agent — for the recurring "Contest not found" toast (`:2718-2728`).
   - `render "contests/hero"` (`app/views/contests/show.html.erb:26`) and
     `render "contests/contest_header"` (`:29`) are unconditional. Only the
     matchup board is gated: contest `open?`, not cancelled, and the viewer
     holding no entry — unless `show_board_for_existing_entry` opens it back
     up for `?add_entry=true` (`:69`).
   - The board partial mounts `x-data="selectionBoard()"` —
     `app/views/contests/_turf_totals_board.html.erb:2092`. The factory is
     defined inline as `window.selectionBoard = function()` (`:171`) because
     Alpine processes `x-data` before importmap modules load (see
     `docs/UI_PATTERNS.md` § Alpine + ERB Constraints).
   - Board config — picks_required, matchup data, contest slug, cart state — is
     serialized into the `board-config` JSON block (`:72-155`) and read once by
     the factory (`:172-173`). Auth state is never copied there: the `loggedIn`
     getter reads `Alpine.store('session')` live on every access (`:198`).

3. **Build cart (no auth required).** Guest taps matchup cards. Each tap calls
   `selectionBoard.toggleSelection(matchupId)` —
   `_turf_totals_board.html.erb:669-751`.
   - Hard-capped at `contest.picks_required` (6 for Turf Totals). A tap past the
     cap replaces the oldest pick rather than refusing (`:697-707`).
   - A guest's tap only mutates local Alpine state — the method returns before
     the network call (`:714`).
   - When logged in it POSTs `/contests/:id/toggle_selection` (`:716-723`) →
     `ContestsController#toggle_selection`
     (`app/controllers/contests_controller.rb:1525-1546`), which finds or
     creates the user's `:cart` entry (`:1533`) and toggles a `Selection`
     through `Entry#toggle_selection!` (`app/models/entry.rb:42-67`).
   - The server's selection set is authoritative; the client adopts it rather
     than trusting its own optimistic mutation
     (`_turf_totals_board.html.erb:750`).
   - At `picks_required` selections the board blurs behind the cart —
     `blurDismissed` gates the overlay (`:2103-2109`) — and the shared
     `render 'studio/hold_button'` appears (`:2282`).

4. **Hold-to-Confirm fires.** The shared hold button dispatches the
   `hold-confirm-entry` window event; the board's `init()` listener routes it
   into `confirmEntry()` (`_turf_totals_board.html.erb:356-363`).
   - `runHoldValidations()` (`:1540-1570`) hits `GET /geo/check` first
     (`:1542`); a blocked state aborts into the `Location Restricted` redirect
     modal (`:1546`). That route is drawn by the engine now, behind
     `config.draw_geo_routes`, not by this app (`config/routes.rb:664-670`).
   - `confirmEntry()` (`_turf_totals_board.html.erb:1587-2076`) short-circuits
     to `showLoginModal()` when the session is a guest (`:1596-1600`), which
     opens the auth wizard at `step: 'credentials'` (`:955-968`) — the entry
     into step 5.
   - `Alpine.store('session').isGuest` is the canonical guest pivot, derived
     from `SessionContext#mode` (`studio-engine: app/models/session_context.rb`)
     and hydrated from the `session-context` JSON block on every render
     (`app/views/layouts/application.html.erb:247`).

5. **Sign up via Phantom.** Choosing Solana in that wizard calls
   `openWalletConnect(ageAttested)`
   (`app/views/contests/_turf_totals_board.html.erb:1043-1048`), which swaps in
   solana-studio's wallet picker. The picker runs
   `window.solanaConnectAndVerify` — `app/views/layouts/application.html.erb:341`.
   - The nonce is fetched from `/auth/solana/nonce` (`:377`) →
     `SolanaSessionsController#nonce`
     (`app/controllers/solana_sessions_controller.rb:5-9`).
   - Two signing paths. A wallet that supports SIWS `signIn` is used directly;
     otherwise the message is built locally — domain, pubkey, statement,
     `Nonce:` — and signed with `provider.signMessage`
     (`app/views/layouts/application.html.erb:545-546`).
   - The `User-ID` binding that ties a signature to an account (OPSEC-005) rides
     only on the wallet-LINK path (`opts.linkMode`), not on signup (`:435`).
   - The signature is base58-encoded and POSTed to `/auth/solana/verify`
     (`:725`) as `signatureB58` alongside the message and pubkey (`:810`).
     An unreadable answer to that POST — an HTML body from a fault of ours,
     which usually arrives as a 302 followed to status 200 rather than a 500;
     see docs/AUTH.md — is
     substituted inside `.json()` and named as our server's fault rather than
     mapped into balance advice (closed 2026-09-09; see `docs/AUTH.md`).

6. **Server verifies + creates User.** `SolanaSessionsController#verify` —
   `app/controllers/solana_sessions_controller.rb:25-108`.
   - Signature check: `Solana::SessionAuth#verify_solana_signature!`
     (`studio-engine: app/controllers/concerns/solana/session_auth.rb`) runs
     pure-Ruby ed25519 through `Solana::AuthVerifier.verify!` — nonce
     delete-before-verify, host bind, TTL. **No Solana RPC call** during signup
     (OPSEC-044 — see `docs/SIGNUP_FLOWS.md`). Called at `:26-31`.
   - `User.from_solana_wallet(pubkey_b58)` looks up an existing user
     (`app/models/user.rb:245-247`); if absent, `verify` builds a new `User`
     with `web3_solana_address` and `reference: cookies[:reference]` — the
     first-touch stamp set in step 1
     (`app/controllers/solana_sessions_controller.rb:38`, `:57-61`).
   - `user.save!` triggers the shared spine. Declaration and definition sit far
     apart in `app/models/user.rb`, so both are cited:
     - `before_validation :ensure_username` (`app/models/user.rb:109`) —
       `ensure_username` auto-fills a username via
       `Studio::UsernameGenerator.generate` (`:766-781`).
     - `before_create :set_initial_session_token` (`:111`) — writes
       `users.session_token` for OPSEC-045 cookie binding (`:536-538`).
     - `after_create :generate_managed_wallet!` (`:126`) — generates a
       server-managed ed25519 keypair with `Solana::Keypair.generate` (`:596`,
       local, no RPC), encrypts the secret key (`:599`), and writes
       `web2_solana_address` + `encrypted_web2_solana_private_key`. It bails for
       admins (`:595`) and, under `AppFlags.web3_only_onboarding?`, for everyone
       (`:589`). The key material itself is read a layer down, in
       `Solana::Keypair.current_encryptor`
       (`app/services/solana/keypair.rb:214-216`).
     - `after_commit :enqueue_onchain_account_setup`
       (`app/models/user.rb:130`) →
       `CreateOnchainUserAccountJob.perform_later` (`:822-824`). Async — the
       user is logged in before the on-chain PDA finalizes.
   - `cookies.delete(:reference)` consumes the cookie only for a new signup
     (`app/controllers/solana_sessions_controller.rb:67`).
   - `set_app_session(user)` writes `session[:turf_user_id]` +
     `session[:session_token]` and clears any stale on-chain flag
     (`app/controllers/application_controller.rb:39-72`, `:47`).
     `promote_to_onchain_session!` then grants it (`:601-606`) — that write is
     what `onchain_session?` reads (`:580-583`), and `verify` calls it at
     `app/controllers/solana_sessions_controller.rb:82`. It lives in
     `ApplicationController` because the login and wallet-link paths used to
     drift apart.
   - Response: `render json: { success: true, redirect: redirect, new_user:
     is_new }` (`:101`).
   - **The in-board flow does not follow that redirect.** The board's
     `openWalletConnect(ageAttested)` saved the guest lineup before handing off
     to the picker and set `returnUrl` to this contest
     (`_turf_totals_board.html.erb:1043-1048`), so the user lands back on the
     contest page with the cart persisted and replayed by `init()` (`:496-508`).

7. **Background: on-chain UserAccount PDA created.**
   `CreateOnchainUserAccountJob#perform` —
   `app/jobs/create_onchain_user_account_job.rb:10-19`.
   - Skips a user with no wallet (`:12`), then calls
     `Solana::Vault#ensure_user_account` (`:14`).
   - `ensure_user_account` is an idempotent no-op when the PDA already exists —
     the `:ok` status returns `nil` (`app/services/solana/vault.rb:1451-1460`,
     `:1454`) — so Sidekiq retries are safe.
   - The job logs and re-`raise`s so Sidekiq retries
     (`app/jobs/create_onchain_user_account_job.rb:16-18`).
   - This is the FIRST on-chain TX in the whole flow — signup itself is pure
     ed25519. The job runs out-of-band; entry submission below does NOT block on
     it, because the entry path re-asserts `ensure_user_account` synchronously
     (see step 9).

8. **Post-reload: cart hydrates + auto-enter fires.** Board `init()` reads the
   saved lineup out of `localStorage`, discarding one older than 30 minutes or
   belonging to another contest (`_turf_totals_board.html.erb:472-476`).
   - Hydrates `selections` + `selectionOrder` and opens the cart (`:481-485`).
   - When the session is logged in, the lineup asked to auto-enter, and the
     count matches `picksRequired`, `init()` schedules `afterLoginSuccess()`
     (`:487`, `:505-507`). A pending wallet-setup prompt re-saves the cart
     instead, so linking Phantom cannot cost the user their lineup (`:496-498`).
   - `afterLoginSuccess()` (`:1381-1410`) surfaces an eligibility blocker first,
     then replays the picks to the server through `replaySelectionsToServer()`
     (`:1127-1144` — one `toggle_selection` POST per pick) and calls
     `confirmEntry()`.

9. **Web3 entry: prepare + sign + confirm.** `confirmEntry()` branches on
   `sess.isWeb3 && this.contestOnchain`
   (`_turf_totals_board.html.erb:1651`) and hands the whole trip to one
   `window.tmWalletOp('contest_entry', …)` call (`:1698`). The runner
   (`app/views/shared/_wallet_op_runner.html.erb`) supplies the return address,
   cluster and transport fork. The flow itself is the `contest_entry` intent,
   registered by name from the layout so the wallet's callback page can finish
   it.
   - **Wallet re-assert.** The board declares `expectedAccount: sess.address`
     (`_turf_totals_board.html.erb:1713`), and solana-studio's `walletOps`
     refuses a different connected wallet before it signs. On the inline
     transport it connects before `prepare`, so no prepared transaction is
     minted for the wrong wallet.
   - **`POST /contests/:id/prepare_entry`** from the intent's
     `tmPrepareContestEntry`
     (`app/views/shared/_contest_entry_intent.html.erb:133-135`) →
     `ContestsController#prepare_entry`
     (`app/controllers/contests_controller.rb:982-1155`).
     - Requires `onchain_session?` — a session with no live wallet signature
       gets 403 `"Phantom session required"` (`:1003`).
     - A retired-format contest never reaches this action: the
       `refuse_retired_format` filter answers 422 first.
     - Server validates: the contest is `onchain_verified?` (`:1032`), a Phantom
       wallet is present (`:1033`), there is capacity (`:1035-1036`), the entry
       holds exactly `picks_required` selections (`:1039`), and no picked game
       has started (`:1040-1042`). Then it assigns the entry number
       (`:1051`).
     - `Solana::Vault#ensure_user_account` runs synchronously here (`:1060`),
       closing the race where the async `CreateOnchainUserAccountJob` has not
       landed yet.
     - **Two funding shapes.** Holding an unconsumed entry token builds
       `build_enter_contest_with_token` (`:1080-1086`); otherwise the currency
       is resolved USDC-or-USDT (`:1013-1029`) and it builds
       `vault.build_enter_contest` (`:1097-1103`,
       `app/services/solana/vault.rb:2258`). Either way the transaction comes
       back FULLY UNSIGNED.
     - Persists a `PendingTransaction` with `tx_type: "enter_contest"`,
       `status: "pending"`, `target: entry` and a metadata blob naming the entry
       PDA and funding shape
       (`app/controllers/contests_controller.rb:1112-1132`). It carries no
       signature yet — nothing has been broadcast. Survives a mid-flight
       refresh; see failure modes below.
     - Returns `{ success, serialized_tx, entry_id, entry_pda, ptx_slug,
       token_funded }` (`:1134-1151`).
   - **Phantom signs FIRST, and the browser does not broadcast.** The intent
     declares `signOnly: true`
     (`app/views/shared/_contest_entry_intent.html.erb:68`), so `walletOps`
     asks the wallet to sign and never to send. The provider's codec
     re-serializes with `requireAllSignatures: false` — the admin slot is
     deliberately still empty (`app/javascript/wallet_provider.js:99-101`).
     Phantom signing an entirely unsigned transaction is what clears Phantom's
     multi-signer "could be malicious" banner.
   - **`POST /contests/:id/confirm_onchain_entry`** with those wire bytes as
     `signed_tx`, from the intent's `tmCompleteContestEntry`
     (`app/views/shared/_contest_entry_intent.html.erb:265-268`) →
     `ContestsController#confirm_onchain_entry`
     (`app/controllers/contests_controller.rb:1350-1503`). The server owns
     everything from here — it judges the wire, cosigns with
     `Transaction.cosign_wire`, simulates, broadcasts and waits
     (`Solana::Cosign::Completer#complete`).
     - Re-runs `entry.assert_enterable!` BEFORE anything irreversible (`:1375`).
     - `Solana::Vault#cosign_expectation` (`:1404-1408`,
       `app/services/solana/vault.rb:3523-3544`) rebuilds the expectation from
       the wire the server stored on the `PendingTransaction`, for this entry
       and wallet, and `Solana::Cosign::Expectation` judges the returned bytes
       against it before anything is signed.
     - `Solana::Vault#cosign_and_broadcast_entry` (definition
       `app/services/solana/vault.rb:3647-3652`, called at
       `app/controllers/contests_controller.rb:1426-1432`) fills the admin
       slot, runs a simulation pre-flight, then sends and waits for
       confirmation.
     - Its `before_send:` callback stamps the `PendingTransaction` `submitted`
       with the signature (`:1429`) BEFORE the bytes leave the server, not
       after. That closes a real gap the old after-broadcast stamp left: a
       crash between broadcast and stamp used to leave a PT reading "never
       broadcast" for money that had already moved, so recovery could let the
       user pay a second time.
     - **OPSEC-010 server-side proof.** `verify_and_confirm_onchain_entry!`
       re-derives the entry PDA through `Solana::Vault#entry_pda`
       (`app/services/solana/vault.rb:465-470`) and refuses a client-supplied
       PDA that disagrees
       (`app/controllers/contests_controller.rb:2673-2690`, `:2678`). Then
       `verify_solana_transaction!` (`:2579-2588`) fetches the transaction from
       chain through `Solana::TxVerifier` and asserts the instruction
       discriminator — `enter_contest` or `enter_contest_with_token`, whichever
       was built — was signed by the user's wallet and wrote the derived PDA
       (`:2680-2685`).
     - `entry.confirm_onchain!(tx_signature:, entry_pda:)` (`:2688`) →
       `app/models/entry.rb:262-292`. Inside a `user.with_lock` transaction
       (`:269`) it re-checks `assert_enterable!` (`:270`), refuses an entry with
       no verified signature (`:280-282`), then `update!(status: :active,
       onchain_tx_signature:, onchain_entry_id:)` (`:284-288`). The re-check
       judges its two TIME gates (contest lock, team kickoff) as of the moment
       the pre-flight passed, not now: the money has already moved, so a team
       that kicked off during the broadcast must not strand a paid entry. Crash
       recovery uses the transaction's blockTime for the same purpose.
     - The `PendingTransaction` is stamped `confirmed` once the entry is
       active (`app/controllers/contests_controller.rb:1443`).
     - `post_entry_seeds_payload` (`:2024-2027`) reads
       `Solana::Vault#seeds_for_entry` to mirror the on-chain award and
       refreshes the total through `sync_balance`; both reads are in
       `Entries::PostEntryEffects.call`
       (`app/services/entries/post_entry_effects.rb:22`, `:28-30`).
   - Modal closes; the seeds bar animates; `lobbyUrl` drives the countdown
     redirect back to the contest page. It is set by the shared painter both
     transports reach, never by the board
     (`app/views/shared/_contest_entry_intent.html.erb:416`).

## Data touched

- `landing_pages` (read in step 1)
- `cookies[:reference]` (write in step 1 — funnel-attribution stamp)
- `contests` (read in steps 2, 3 and 9; the row is locked via `@contest.with_lock`
  for `ContestsController#enter`, inside `Entries::ManagedEntry#call`
  (`app/services/entries/managed_entry.rb:77`), not in `#prepare_entry` or
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
  (`app/controllers/application_controller.rb:601-606`)
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
  integrity (`app/views/contests/_turf_totals_board.html.erb:1736-1742`).

## Failure modes

- **`?reference=` cookie collision.** A user who clicks Landing Page A and then
  Landing Page B keeps A's attribution: both `capture_reference` and
  `LandingPagesController#show` only set the cookie when it is blank
  (`app/controllers/landing_pages_controller.rb:17`). Symptom:
  `User.reference` does not match the page that converted them.
- **No on-chain Contest PDA.** Paid contests refuse free entry —
  `ContestsController#enter` refuses with `"This contest isn't on-chain yet — paid
  entry is unavailable."`, raised by `Entries::ManagedEntry#call`
  (`app/services/entries/managed_entry.rb:99-101`).
  `Entry#confirm!` carries the model-level backstop for the same hole, with its
  own wording: `"Entry payment required — no entry token consumed or on-chain
  payment recorded"` (`app/models/entry.rb:205-207`). Always set the contest
  on-chain before publishing the landing page.
- **No active season.** `#enter` refuses with `"No active season configured. Set one
  at /admin/seasons before users can enter on-chain contests."`, raised by
  `Entries::ManagedEntry#call` (`app/services/entries/managed_entry.rb:88-93`) — the operator must call
  `SeasonConfig.set_current!(season_id)` first. Caught before the user spends a
  Phantom signature.
- **Wrong wallet connected.** `confirmEntry` declares the session address as
  `expectedAccount`
  (`app/views/contests/_turf_totals_board.html.erb:1713`), and solana-studio's
  `walletOps` refuses a different connected wallet with a sentence naming both.
  The board adds "Or reconnect your wallet on the Account page." (`:1959-1960`).
  The user must reconnect the wallet that owns the account, or switch Phantom's
  active wallet.
- **Refresh mid-flight (signed, handed to the server, awaiting confirmation).**
  Covered by `PendingTransaction`. On the next page load
  `find_pending_recovery_ptx`
  (`app/controllers/contests_controller.rb:2832-2852`) puts the slug into the
  board config, `init()` calls `recoverPendingEntry()`
  (`app/views/contests/_turf_totals_board.html.erb:531-571`, POST at `:543`),
  and `ContestsController#recover_pending_entry`
  (`app/controllers/contests_controller.rb:1229-1337`) polls the signature once
  (`:1278`): still propagating renders `processing` (`:1280-1292`), an
  on-chain error marks it `failed` (`:1294-1296`), and a landed transaction is
  verified and promoted to `active` (`:1311-1315`). The CLIENT owns the polling
  cadence; the only server-side clock sweeps signature-less rows older than ten
  minutes to `expired` (`:2847-2849`).
- **Refresh between sign and hand-off.** The server never received the bytes, so
  `ptx.tx_signature` is blank — and the recovery modal never opens for it.
  `find_pending_recovery_ptx` returns only signature-carrying rows and sweeps
  the signature-less ones to `expired` after ten minutes (`:2847-2849`), so the
  board config gets no slug and `recoverPendingEntry()` is never called. The
  user is released silently; nothing was broadcast, so nothing is owed. The
  blank-signature branch inside `recover_pending_entry` — `"Your last entry did
  not go through — try again."` (`:1269-1271`) — is defense-in-depth for a
  caller that supplies such a slug directly, not a message this flow produces.
- **OPSEC-010 PDA mismatch.** `verify_and_confirm_onchain_entry!` raises
  `"Entry PDA mismatch"` when the client-supplied `entry_pda` differs from the
  server-derived one (`:2678`). Surfaces as a red Solana modal; the entry
  stays in `:cart` and the user can retry. `#recover_pending_entry` omits the
  client value deliberately and skips that cross-check (`:1312-1314`).
- **Sybil duplicate-combo entry.** `Entry#assert_enterable!` raises `"You
  already have an entry with this exact selection combination"`
  (`app/models/entry.rb:164-169`). The user must change at least one pick.
- **Per-user entry limit.** `Contest#max_entries_per_user` (3 for Turf Totals)
  is enforced by `assert_enterable!` inside the same `user.with_lock`
  (`:161-162`).
- **Start window crossed during signing.** `assert_enterable!` raises
  `"Contest has locked — entries closed"` once `contest.locks_at` has passed
  (`:145-147`), so a stale Phantom prompt cannot squeak through after lock.
  Prelaunch audit H7 fix — closes the staggered-kickoff info-edge attack.
- **`CreateOnchainUserAccountJob` failure.** `#perform` logs and re-`raise`s for
  Sidekiq retry (`app/jobs/create_onchain_user_account_job.rb:16-18`).
  `#prepare_entry`'s synchronous `ensure_user_account`
  (`app/controllers/contests_controller.rb:1060`) covers the case where the job
  has not yet succeeded by entry time.

> **Orphaned endpoint.** `ContestsController#stamp_entry_signature`
> (`app/controllers/contests_controller.rb:1205-1217`, routed as
> `post :stamp_entry_signature` at `config/routes.rb:356`) is no longer called
> by any client. It belonged to the
> browser-broadcast flow, and the comment that replaced it says so —
> `the client no longer calls stamp_entry_signature before confirm`
> (`app/controllers/contests_controller.rb:1349`). Only tests reach it now,
> and its own header comment still describes the retired
> `connection.confirmTransaction` wait (`:1199-1204`).

## Related workflows

- [[admin-contest-setup]] — predecessor: an operator must publish the on-chain
  Contest PDA + active LandingPage before this flow can run.
- [[email-signup-token-to-chat]] — alternate signup lane (web2 / managed
  wallet) starting from the same landing page; diverges at step 5 into
  Stripe token purchase rather than Phantom signing.
- [[referral-google-tokens-to-chat]] — alternate signup lane (Google
  OAuth) sharing the same `cookies[:reference]` first-touch attribution
  set in step 1.

<!-- citation-guard: enforced -->
