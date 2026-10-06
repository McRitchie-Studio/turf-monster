# Workflow: admin-contest-setup

> **Code is law.** Every claim below cites `path/to/file.rb:NN` from the current
> codebase, and a bare `:NN` inherits the nearest preceding path — file context
> resets at each `##` heading. The number is bookkeeping; the SYMBOL beside it is
> the claim, and `test/docs/workflow_citation_docs_test.rb` reddens when a
> citation stops landing inside the definition its prose names.
> That symbol check reaches **188 of the 231 citations** here. The other **43**
> sit in code with no enclosing definition the guard can derive, and they are not
> all checked alike. **6 of those 43** are `config/routes.rb` entries, which get a
> stricter check: each must OPEN on the line that carries its route, not merely
> quote a word found somewhere in its span. That catches most one-line drift, not
> all of it — [the workflows README](README.md) has the measurement. The rest — one
> `config/schedule.yml` job, ERB markup and form fields, class-body `before_action`
> / `include` / `after_create` declarations, two constants, and two lines of
> `docs/SOLANA.md` prose — ride the weaker LITERAL fallback: it proves the words the
> prose quotes are present in the cited lines, not that the code is.
> **All 14 citations on `app/views/layouts/application.html.erb`
> and `app/views/shared/_contest_create_intent.html.erb`** — the Phantom SIWS
> surface and the contest-create signing intent, i.e. every wallet-facing claim in
> this document — ride that fallback, and the cause is mechanical rather than editorial:
> both are written `window.name = async function (…)`
> (`window.solanaConnectAndVerify`, `window.tmPrepareContestCreate`), a shape the
> guard's brace-balance parser does not read as a definition, so no line in their
> bodies has a symbol to anchor on. A reader following a signing claim is therefore
> the reader most likely to land on the weak branch.
> Cross-repo `studio-engine:` references carry NO line number on purpose — the gem is
> versioned, so a number in it would rot on an unrelated `bundle update`.
>
> **Refresh status:** Fully re-verified against `accepted` on 2026-09-09. Two
> STRUCTURAL corrections since the last pass, both of which had inverted the
> meaning of step 3: contest creation now writes a **write-ahead `pending` DB row
> BEFORE the prize pool moves** (it used to write the row only after the chain
> confirmed), and the **server**, not the browser, cosigns and broadcasts the
> `create_contest` transaction.

**Trigger:** Operator (admin) opens the app to spin up a brand-new on-chain contest and enter it themselves.
**Actors:** Admin (Phantom wallet) / Phantom / Rails / Solana RPC / turf-vault Anchor program / Squads (only if the vault has never been initialized on this program).
**Outcome:** New on-chain `Contest` PDA funded with the prize pool; matching DB `Contest` row promoted to `open`; admin's `Entry` PDA created + DB entry `active`; admin's `UserAccount` PDA seeded.
**Preconditions:**
- Admin has `role == "admin"` (`User#admin?` — `app/models/user.rb:266-268`) and a linked Phantom wallet (`web3_solana_address`). Admins are web3-only by policy — `User#generate_managed_wallet!` early-returns for admins (`app/models/user.rb:589`, OPSEC-044).
- `EXPECTED_IDL_HASH` matches the IDL THIS app selects — `config/turf_vault.idl.json` on devnet with the governance switch off, one of four artifacts keyed by `SOLANA_NETWORK` and `SOLANA_VAULT_GOVERNANCE` (`lib/solana/idl_selection.rb`). Verified at boot — `Solana::Config.verify_idl!`, `app/services/solana/config.rb`.
- An active `SeasonConfig.current_season_id` exists. Without it, `ContestsController#enter` refuses before any consume: `Entries::ManagedEntry#call` raises inside the contest lock (`app/services/entries/managed_entry.rb:88-93`).

## Sequence

### 1. Admin logs in via Phantom (SIWS)

1. **Click "Connect Wallet"** — the multi-wallet picker modal (solana-studio's `solana_studio/modals/_wallet_connect`, mounted from `app/views/layouts/application.html.erb` with `wallet_connect_modal_locals`) invokes the inline `window.solanaConnectAndVerify` SIWS helper (`app/views/layouts/application.html.erb:341`). Alpine `x-data` factory functions must be inline because `importmap` modules load *after* Alpine processes `x-data` (`app/views/layouts/application.html.erb:1582-1584`).
2. **`GET /auth/solana/nonce`** — `SolanaSessionsController#nonce` (`app/controllers/solana_sessions_controller.rb:5-9`). Stores `session[:solana_nonce]` + `session[:solana_nonce_at]`.
   - Route: `solana_sessions#nonce` (`config/routes.rb:210`).
3. **Client builds the SIWS message** and calls `provider.signMessage(...)` — `app/views/layouts/application.html.erb:545-546`. The helper prefers the wallet's own `signIn` and falls back to `connect` + `signMessage`, announcing the fallback with a `console.warn` at `:520`. The message body begins `wants you to sign in with your Solana account` (`:545`), and the nonce echoed back is checked against `nonceData.nonce` (`:485`).
   - Message format: `"<host> wants you to sign in with your Solana account:\n<pubkey>\n\n<userIdLine>Sign in to Turf Monster\n\nNonce: <nonce>"`. The opening `<host>` token is the OPSEC-018 host binding the server later asserts. `<userIdLine>` is empty at login (no `current_user` yet) and only present when re-signing inside an authenticated session (OPSEC-005 — see step 4).
4. **`POST /auth/solana/verify`** — `SolanaSessionsController#verify` (`app/controllers/solana_sessions_controller.rb:25-107`), routed as `solana_sessions#verify` (`config/routes.rb:211`).
   - `verify_solana_signature!` (`app/controllers/solana_sessions_controller.rb:26`) deletes the nonce before verifying (replay protection) and delegates to `Solana::AuthVerifier.verify!` in the solana-studio gem with `expected_host: request.host_with_port`. The method is `Solana::SessionAuth#verify_solana_signature!`, which lives in **studio-engine** (`studio-engine: app/controllers/concerns/solana/session_auth.rb` — it deletes the nonce before verifying and binds the OPSEC-005 `User-ID:` line) and is mixed in via `include Solana::SessionAuth` (`app/controllers/solana_sessions_controller.rb:2`, `app/controllers/accounts_controller.rb:3`, `app/controllers/entries_controller.rb:2`). `ContestsController` no longer includes it: `#enter`'s signature branch was the controller's only caller and it now refuses a web3 session outright.
   - Looks up the user by wallet with `User.from_solana_wallet(pubkey_b58)` (`app/models/user.rb:239-241`) — a plain `find_by`, no create. `SolanaSessionsController#verify` is what builds the row when the lookup misses (`app/controllers/solana_sessions_controller.rb:57`).
   - `set_app_session(user)` at `:67` (`app/controllers/application_controller.rb:36-50`) writes the session-token cookie and explicitly **clears** any stale `session[:onchain]` flag (`session.delete(:onchain)` — `app/controllers/application_controller.rb:44`). `SolanaSessionsController#verify` then re-grants it through `promote_to_onchain_session!` (`app/controllers/solana_sessions_controller.rb:81`), because this auth path is a genuine Phantom signature.
5. **Admin gate** — every admin route runs the class-body `before_action :require_admin` (`app/controllers/contests_controller.rb:15`). The helper is `Studio::ErrorHandling#require_admin` in `studio-engine` (`studio-engine: app/controllers/concerns/studio/error_handling.rb`), which redirects with "Not authorized" unless `logged_in? && current_user.admin?`.

### 2. Initialize on-chain accounts — **conditional**

The `if needed` branch in the user's mental model maps to three distinct chain-init paths. Only the first is rare; the other two run silently on demand.

#### 2a. One-time vault init (rare — once per program ID)

Surfaced from the admin Link Hub as **"Vault Init"** when the vault is uninitialized, and from the Vault State page when an operator needs the direct init path:

- Visibility check: `Admin::VaultInitController.vault_uninitialized?` (`app/controllers/admin/vault_init_controller.rb:124-130`) — it calls `Solana::Vault#read_vault_state` (`app/services/solana/vault.rb:857-944`) and caches the boolean. `Admin::VaultInitController#confirm` busts that cache on success (`app/controllers/admin/vault_init_controller.rb:104`).
- Both entry points link to `admin_vault_init_path` — the Link Hub tile (`app/views/admin/hub.html.erb:71`) and the Vault State fallback link (`app/views/admin/vault_state/show.html.erb:20`).
- Routes: `config/routes.rb:594-596` — `vault_init#show`, `vault_init#build`, `vault_init#confirm`.
- Flow:
  1. `Admin::VaultInitController#build` (`app/controllers/admin/vault_init_controller.rb:64-86`) refuses an already-initialized vault (`:66`), runs `Admin::VaultInitController#validate_init_params!` (`:138-159` — three distinct signers `:149`, threshold 1-3 `:150`, creator must be one of the signers `:151` and must equal `INIT_AUTHORITY` on mainnet `:156-157`), then calls `Solana::Vault#build_initialize_vault` (`app/services/solana/vault.rb:758-789`). The bot fee-pays; the creator slot is left for Phantom.
  2. Phantom cosigns + broadcasts client-side. This is the one flow in this document where the browser still broadcasts.
  3. `Admin::VaultInitController#confirm` (`app/controllers/admin/vault_init_controller.rb:88-112`) verifies the TX with `Solana::TxVerifier.verify!` (`:97`) against the `initialize` discriminator, the vault PDA as writable, and the creator as signer, then deletes the cache key (`:104`).
- **Today's reality:** live devnet/mainnet program identity is canonical in `/Users/alex/projects/turf-vault/docs/CURRENT_DEPLOYMENT.md`. The admin will not see Vault Init on an already-initialized program; this branch only fires the first time the app points at a fresh program ID.

#### 2b. Per-season seed-schedule init (rare — once per Season)

`ContestsController#enter` refuses with **"No active season configured. Set one at /admin/seasons before users can enter on-chain contests."** when `SeasonConfig.current_season_id.to_i.zero?`: `Entries::ManagedEntry#call` raises it (`app/services/entries/managed_entry.rb:88-93`) inside the contest `with_lock` and before any consume. Step 4 fails loudly if step 2b was skipped. Contest *creation* has its own parallel guard: `ContestsController#onchain_season_error` (`app/controllers/contests_controller.rb:2359-2376`) returns "…before creating on-chain contests." and `#ensure_onchain_season_ready!` (`:2353-2357`) raises it.

- Admin UI: `Admin::SeasonsController#create` (`app/controllers/admin/seasons_controller.rb:11-39`) reads `name`, `season_id`, and `slot_0..slot_4` from the form (`:14`), validates the five slots (`:22`), calls `Solana::Vault#create_season(season_id:, name:, schedule:)` (`:31`, definition `app/services/solana/vault.rb:3008-3055`), and — when `params[:set_current] == "1"` — flips `SeasonConfig.set_current!(season_id)` (`app/controllers/admin/seasons_controller.rb:32`).
- Routes: `seasons#create` and `seasons#set_current` (`config/routes.rb:624-625`).
- The on-chain `Season` PDA lives at `[b"season", season_id_le]` — derived by `Solana::Vault#season_pda` (`app/services/solana/vault.rb:531-534`) — and stores the `seed_schedule` (default `[25, 19, 14, 10, 7]`) the `enter_contest` instruction reads to award seeds (see `docs/SOLANA.md`).

#### 2c. Per-contest Contest PDA init — **fires every time** in step 3

The contest PDA at `[b"contest", sha256(slug)]`, derived by `Solana::Vault#contest_pda` (`app/services/solana/vault.rb:453-456`), is created by the `create_contest` instruction in step 3 below. There is no separate "init contract" click for this.

#### 2d. Per-user UserAccount PDA — fires lazily on first entry

`Solana::Vault#ensure_user_account` (`app/services/solana/vault.rb:1455-1464`) is called inline by every entry path — `ContestsController#prepare_entry` calls it at `app/controllers/contests_controller.rb:1045` (step 4). It checks the PDA size and either no-ops, creates the PDA via `Solana::Vault#create_user_account` (`app/services/solana/vault.rb:1466-1513`), or raises on schema drift. For most admins this is a no-op, because the class-body `after_commit :enqueue_onchain_account_setup, on: :create` (`app/models/user.rb:130`) already ran `User#enqueue_onchain_account_setup` (`:811-813`) at signup, enqueuing `CreateOnchainUserAccountJob` (`app/jobs/create_onchain_user_account_job.rb`; see `docs/AUTH.md`).

### 3. Admin creates a contest

Phantom-driven, four server round-trips. **The DB row is written BEFORE the money moves**, deliberately: `finalize` saves a `pending` contest carrying the derived PDA, broadcasts, records the signature, and only then verifies and promotes the row to `open`. A broadcast that succeeds while a later step fails therefore leaves a `pending` row an operator can find — not a funded PDA with nothing pointing at it.

1. **`GET /contests/new`** — `ContestsController#new` (`app/controllers/contests_controller.rb:101-117`). The form lives at `app/views/contests/new.html.erb`: the `f.collection_select :slate_id` slate picker at `app/views/contests/new.html.erb:84-86`, the `contest[week_span]` select at `:93-95`, `contest_type` at `:123-125`, the hidden `contest_starts_at` **Starts At** field at `:152-153`, and `contest_image` at `:260`. `contest_type` must be one of `Contest.selectable_formats` (`app/models/contest.rb:338-340`; it respects the `ENABLE_TEST_SCAFFOLDING` flag via `AppFlags.test_scaffolding?`). The visible field is **Starts At**, which is the contest LOCK: defaulted by `ContestsController#default_start_for_slate` (`app/controllers/contests_controller.rb:2869-2871`) to the slate's default lock — 11:00 America/Denver on an NFL slate's opening Sunday, the first kickoff for every other sport (`Contest::LockRule`); `Contest#locks_at` (`app/models/contest.rb:788-790`) is what the countdown and the on-chain lock timestamp use. `entry_fee_cents` + `max_entries` are derived server-side from `Contest#format_config` (`:349-351`) inside `ContestsController#build_unpersisted_contest_from_params` (`app/controllers/contests_controller.rb:2121-2135`, at `:2124-2125`).
   - **Slate span (slates-sport-year):** the operator may extend a single slate into a **multi-week span** with the `week_span` field. `ContestsController#resolve_span_slate` (`app/controllers/contests_controller.rb:2146-2176`) turns "N weeks from this anchor" into the ONE span slate the contest is played on, building it with `Nfl::BuildSpanSlate.call` if needed (`:2172`). The span is scoped to the anchor slate's season through the **`slates.year` column**, read via `Slate#season_year` (`:2158`), and to its `season_type` (`:2172`) so a preseason anchor cannot yield regular-season weeks. A refusal is captured in `@span_slate_error` (`:2174`) and `ContestsController#create` renders it rather than silently building a shorter contest (`:312-314`). Slate classification reads the **`slates.sport` column** via `Slate#sport`, surfaced by `ContestsController#sport_for_slate` (`:2881-2883`); selectable slates come from `#contest_slate_options` (`:2863-2867`). A span of 1 leaves the plain `slate_id` select untouched (`:2148`).
2. **Submit → `POST /contests`** — `ContestsController#create` (`app/controllers/contests_controller.rb:302-345`):
   - Refuses non-Phantom callers (`:303`).
   - `ContestsController#onchain_create_precheck` (`:2317-2351`, called at `:322-324`) — model validation (`:2322`), slug uniqueness in the DB via `#slug_taken_message` (`:2332`, definition `:2083-2091`), the on-chain Contest PDA must not already exist (`:2338-2344`), season readiness through `#onchain_season_error` (`:2346-2348`), then `ContestsController#insufficient_usdc_error` (`:2393-2433`, called at `:2350`) verifies the creator's ATA balance covers `guaranteed_prize_cents`.
   - `Solana::Vault#build_create_contest` (`app/services/solana/vault.rb:1682-1720`, called at `app/controllers/contests_controller.rb:327-332`) builds a fully UNSIGNED `create_contest` TX with `admin_signs: false` (`:331`) — the admin fee-payer and creator signature slots are both left empty. The account layout is assembled in `Solana::Vault#create_contest_instruction` (`app/services/solana/vault.rb:1722-1765`): payer, creator, vault_state, contest (init), USDC mint, creator_ata, vault_usdc, token program, system program.
   - The server returns `{ serialized_tx, contest_pda, slug, params_token }` (`app/controllers/contests_controller.rb:334-340`). The `params_token` is a `Rails.application.message_verifier` blob with a 10-minute TTL (`ONCHAIN_CREATE_TOKEN_TTL` — `:300`; signed in `ContestsController#sign_onchain_create_payload`, `:2442-2466`) so the server can trust the re-posted form fields in step 3.4 without re-validating them. The banner image rides this PREPARE post, not finalize: `ContestsController#stash_contest_banner` (`:2270-2283`) uploads it as an unattached blob, and its signed id is bound into the token as `contest_image_id` (`:2444`). It has to leave the browser here, because on the redirect transport the page is destroyed while the wallet signs and finalize runs on a document that never held the file input.
3. **Refresh blockhash + wallet SIGN (no client broadcast)** — the form makes ONE call, `window.tmWalletOp('contest_create', …)` (`app/views/contests/new.html.erb:462-476`), and the `contest_create` intent registered by name from `app/views/shared/_contest_create_intent.html.erb:25-29` does the rest on every transport, injected or redirect. Its prepare half, `tmPrepareContestCreate` (`:53-93`), POSTs the whole form as `new FormData(form)` — banner included — to `POST /contests` (`:62-66`), then calls `POST /contests/rebuild_create_tx` to re-issue the unsigned TX over a fresh blockhash (`:77-81`); that is `ContestsController#rebuild_create_tx` (`app/controllers/contests_controller.rb:357-384`, routed by `post :rebuild_create_tx` at `config/routes.rb:341`), and the re-issue goes through the server so the exact message bytes stay bound to the signed `params_token` (`app/controllers/contests_controller.rb:358-371`). The wallet then signs ONLY — the intent is declared `signOnly: true` (`app/views/shared/_contest_create_intent.html.erb:26`) — and the complete half, `tmCompleteContestCreate` (`:98-137`), refuses a wallet that broadcast instead of signing — no `result.signedTransaction` means no bytes for the server to cosign (`:99-102`) and POSTs the signed-but-unbroadcast wire as `signed_tx` to `/contests/finalize` (`:122-130`). There is no `connection.sendRawTransaction` on this path: the browser never touches the RPC.
4. **`POST /contests/finalize`** — `ContestsController#finalize` (`app/controllers/contests_controller.rb:416-529`). Collection route (no `:id`), `post :finalize` at `config/routes.rb:342`. In order:
   - `ContestsController#verify_onchain_create_payload` (`app/controllers/contests_controller.rb:2468-2472`) decodes the `params_token` (`:417`) and the user is re-checked against it (`:418`).
   - `Solana::Vault#contest_pda(slug)` (`app/services/solana/vault.rb:453-456`) re-derives the PDA and `finalize` demands `params[:contest_pda]` match (`app/controllers/contests_controller.rb:420-421`).
   - `Solana::Vault#create_contest_expectation` (`app/services/solana/vault.rb:3480-3495`, called at `app/controllers/contests_controller.rb:439-443`) rebuilds what the server built from its own draft — fee schedule, payouts, prize pool, lock timestamp, slug-derived PDA — as the expectation `Solana::Cosign::Expectation` judges the signed wire against before the server puts its own signature on it.
   - **Write-ahead row.** `ContestsController#build_pending_contest` (`:2218-2256`) constructs the row at `status: :pending` carrying `onchain_contest_id` (`:2232`) and with `skip_onchain_callback = true` (`:2255`) so the legacy `after_create :create_onchain_with_rollback!` hook (`app/models/contest.rb:125`) cannot double-spend. `finalize` saves it at `app/controllers/contests_controller.rb:451`, **before** a lamport moves. `Contest`'s `before_create` binds `season_id` to `SeasonConfig.current_season_id` (`app/models/contest.rb:131`).
   - `Solana::Vault#cosign_and_broadcast_create_contest` (`app/services/solana/vault.rb:3729-3732`, called at `app/controllers/contests_controller.rb:462-466`) judges the signed wire against the expectation, cosigns, and broadcasts. Past this line the money is real.
   - The signature is recorded via that call's `before_send:` callback (`:465`), BEFORE the broadcast is attempted rather than after — the only off-chain evidence tying this request to the on-chain effect.
   - `ContestsController#verify_solana_transaction!` (`:2584-2593`, called at `:485-490`) → `Solana::TxVerifier.verify!` (OPSEC-010) asserts the broadcast TX is the `create_contest` instruction signed by `creator_pubkey` and writing to the derived PDA.
   - Only then is the row promoted to `open` (`:493`), the banner attached last from the stashed blob id the token carries (`:501`) — `ContestsController#attach_contest_banner` (`:2302-2312`) logs rather than raises, so it cannot fail a funded contest — and `{ success: true, redirect: contest_path(contest), slug: }` returned (`:503`).

> **Fallback path — server-funded.** `Contest#create_onchain!` (`app/models/contest.rb:364-387`), wired via the class-body `after_create :create_onchain_with_rollback!` (`:125`, method at `:396-402`), calls `Solana::Vault#create_contest_server_funded` (`app/services/solana/vault.rb:1784-1844`). The admin signs as both payer and creator, with prize-pool USDC funded from the configured server/admin wallet. It is used for Rails console and scripts, and auto-skipped in tests and for any contest already on-chain — `Contest#skip_onchain_callback_active?` (`app/models/contest.rb:389-391`). The UI does not use this path.

### 4. Admin enters their own contest

Admins follow the **same** path as any other Phantom-authenticated user — there is no admin-only shortcut. The `comped: true` escape hatch on `Entry#assert_enterable!` (`app/models/entry.rb:136-148`) and `Entry#confirm!` (`:188-208`) is used **only** by `Contest#fill!` (`app/models/contest.rb:543-585`) for bot-seeded test entries, never by a real admin entering through the UI.

The contest test actions (Fill, Next Game / Simulate, Next 5 / 20, All / Jump, and the hub's Reset Contest) render and answer only while `ENABLE_TEST_SCAFFOLDING` is on, and they refuse, whatever the flag says, any on-chain contest, any contest holding a paid entry (an on-chain payment signature, an entry PDA, or a signed pending entry transaction), and, for every action but Fill, any contest sharing games with an on-chain or paid contest. A refusal is a flash on the contest page.

Two-stage hold-to-confirm followed by the Phantom direct-entry signing flow:

1. **Toggle 6 selections** on the matchup board — `POST /contests/:id/toggle_selection` per click (`ContestsController#toggle_selection` — `app/controllers/contests_controller.rb:1509-1530`). Each call `find_or_create_by!`s the cart entry (`:1517`) and toggles a `Selection` row (`:1520`). World Cup Survivor contests use `ContestsController#pick` instead (`:1533-1562`).
2. **Hold-to-confirm** triggers `confirmEntry()` in `app/views/contests/_turf_totals_board.html.erb:1567-1984`:
   - It branches on `useOnchainFlow = sess.isWeb3 && this.contestOnchain` (`:1631`, taken at `:1645`). Admin = web3 = always the on-chain branch.
   - There is no client-side wrong-wallet throw on this path any more; the binding is server-side (see the failure modes below).
3. **`POST /contests/:id/prepare_entry`** — `ContestsController#prepare_entry` (`app/controllers/contests_controller.rb:1001-1163`):
   - Requires `onchain_session?` (`:1024`) — the admin's Phantom-auth session has it from step 1.
   - Requires a verified on-chain contest and a Phantom wallet (`:1045-1046`), refuses a full contest (`:1048-1049`), validates exactly `picks_required` selections (`:1052` — `Contest#picks_required` at `app/models/contest.rb:267-271`, floored on `TURF_TOTALS_DEFAULT_PICKS_REQUIRED = 6` at `:67`), and refuses if any underlying game is `locked?` (`app/controllers/contests_controller.rb:1053-1055`).
   - Assigns `entry.entry_number` by **probing the chain for a free slot** — `Entry#assign_onchain_entry_number!` (`app/models/entry.rb:328-343`, called at `app/controllers/contests_controller.rb:1064`) reads existing DB entry numbers, then asks `Solana::Vault#next_free_entry_index` (`app/services/solana/vault.rb:477-486`) for the first on-chain-free slot.
   - `Solana::Vault#ensure_user_account(current_user.web3_solana_address, username:)` (`app/controllers/contests_controller.rb:1069`) — see 2d above.
   - `Solana::Vault#build_enter_contest(wallet, slug, entry_num, currency_idx:, season_id:)` (`app/services/solana/vault.rb:2203-2291`, called at `app/controllers/contests_controller.rb:1105-1111`) builds the unified `enter_contest` transaction; a prepared entry token takes `Solana::Vault#build_enter_contest_with_token` instead (`:1088-1094`, definition `app/services/solana/vault.rb:2352-2385`). The Phantom-first flow leaves both signature slots empty — `confirm_onchain_entry` validates the user-signed wire before the server cosigns and broadcasts.
   - Persists a `PendingTransaction` with `tx_type: "enter_contest"`, `status: "pending"` and polymorphic `target: entry` (`app/controllers/contests_controller.rb:1120-1140`), so a mid-flight refresh leaves a recoverable trail.
   - Returns `{ serialized_tx, entry_id, entry_pda, ptx_slug, token_funded, currency }` (`:1142-1159`) — `currency` echoes the server's own pricing decision so the sign card can never name a different token than the transfer it asks for (`:1158`).
4. **Phantom signs, server broadcasts** — the browser signs the prepared wire and posts it to `confirm_onchain_entry`; the server validates the signed wire, cosigns with the admin key, simulates, broadcasts, stamps the `PendingTransaction`, and verifies the resulting signature.
5. **`POST /contests/:id/confirm_onchain_entry`** — `ContestsController#confirm_onchain_entry` (`app/controllers/contests_controller.rb:1348-1487`):
   - It loads the in-flight `PendingTransaction` (`:1383-1385`), then builds `Solana::Vault#cosign_expectation` (`app/services/solana/vault.rb:3436-3457`, called at `app/controllers/contests_controller.rb:1401-1405`) from the wire the server stored on that row — never from the request — so `Solana::Cosign::Expectation` can refuse a wire that is not exactly one `enter_contest` instruction binding the session's wallet to the derived entry PDA.
   - `Solana::Vault#cosign_and_broadcast_entry` (`app/services/solana/vault.rb:3560-3563`, called at `app/controllers/contests_controller.rb:1423-1427`) judges the returned wire against that expectation, cosigns, and broadcasts. Its `before_send:` callback stamps the signature onto the `PendingTransaction` (`:1426`) BEFORE the bytes leave the server, not after — closing the gap where a crash between broadcast and stamp left an unrecorded on-chain payment.
   - `ContestsController#verify_and_confirm_onchain_entry!` (`:2656-2673`, called at `:1433-1436` with the client-supplied `params[:entry_pda]`) re-derives `entry_pda` via `Solana::Vault#entry_pda(slug, wallet, entry_number)` (`app/controllers/contests_controller.rb:2658-2660`, definition `app/services/solana/vault.rb:458-463`) and rejects a mismatched client-supplied PDA (`app/controllers/contests_controller.rb:2661`).
   - `#verify_and_confirm_onchain_entry!` then calls `verify_solana_transaction!` (`:2663-2668`; definition `:2584-2593`), asserting the TX is `enter_contest` signed by the user's wallet and writing to the derived entry PDA (OPSEC-010).
   - `Entry#confirm_onchain!` (`app/models/entry.rb:263-293`) promotes the entry to `active` and stamps `onchain_tx_signature` + `onchain_entry_id`. The `comped:` flag is NOT passed — the on-chain path is user-initiated only, and the on-chain TX itself is the payment proof (`:268-269`).
   - The `PendingTransaction` is marked `confirmed` (`app/controllers/contests_controller.rb:1438`) and the response carries `{ success: true, redirect, tx_signature, seeds_earned, seeds_total, seeds_level }` (`:1455-1463`).

## Data touched

- **DB:**
  - `users` (read — `User.from_solana_wallet` at `app/models/user.rb:239-241`; insert in `SolanaSessionsController#verify` at `app/controllers/solana_sessions_controller.rb:57` on first login for this pubkey)
  - `season_configs` (read — `SeasonConfig.current_season_id`, `app/models/season_config.rb:21-23`)
  - `slates` (read — the selected slate; on a span, its consecutive weekly siblings, scoped by the `year`/`sport`/`season_type` columns in `ContestsController#resolve_span_slate` → `Nfl::BuildSpanSlate` — `app/controllers/contests_controller.rb:2172`)
  - `slate_matchups` (read — the pickable matchups behind the selections)
  - `contests` (insert at `status: :pending` in `ContestsController#finalize` — `app/controllers/contests_controller.rb:451` — then `onchain_tx_signature` stamped via `before_send:` at `:465` and promotion to `open` at `:493`)
  - `entries` (insert via `ContestsController#toggle_selection` at `:1517`; update to `active` via `Entry#confirm_onchain!` at `app/models/entry.rb:263-293`)
  - `selections` (insert per matchup toggle, inside `Entry#toggle_selection!` — `app/models/entry.rb:54`)
  - `pending_transactions` (insert in `ContestsController#prepare_entry` at `app/controllers/contests_controller.rb:1120`; `tx_signature` + `status` updated through the lifecycle by `ContestsController#confirm_onchain_entry` at `:1426` and `:1438`)
  - `transaction_logs` (an audit row written by `Entry#confirm!` when the entry fee is positive — `app/models/entry.rb:210-212`; that is the off-chain `confirm!` path, not the on-chain admin path in step 4)
  - `outbound_requests` (insert per Solana RPC call via `Solana::ClientLogger`)
- **On-chain (turf-vault):**
  - `VaultState` PDA at `[b"vault"]` — `Solana::Vault#vault_state_pda` (`app/services/solana/vault.rb:245-247`); read, and **init** if 2a fires
  - `Season` PDA at `[b"season", season_id_le]` — `Solana::Vault#season_pda` (`:531-534`); read, and **init** if 2b fires
  - `UserAccount` PDA at `[b"user", wallet]` — `Solana::Vault#user_account_pda` (`:448-451`); read, and **init** if 2d fires
  - `Contest` PDA at `[b"contest", sha256(slug)]` — `Solana::Vault#contest_pda` (`:453-456`); **init** via the `create_contest` IX in step 3
  - `ContestEntry` PDA at `[b"entry", contest_pda, wallet, entry_num_le]` — `Solana::Vault#entry_pda` (`:458-463`); **init** via the `enter_contest` IX in step 4
  - SPL token transfers: creator ATA → per-contest prize-pool ATA for the prize pool (step 3); user ATA → per-currency operator-revenue ATA for the entry fee (step 4)
- **External:** Solana RPC. Every `build_*` re-derives its PDAs, and both money paths broadcast SERVER-side after the admin cosign — `Solana::Vault#cosign_and_broadcast_create_contest` (`app/services/solana/vault.rb:3729-3732`) and `#cosign_and_broadcast_entry` (`:3560-3563`). Only the 2a vault init still broadcasts from the browser.

## Failure modes

- **Wrong wallet connected** — on the CREATION form, `new.html.erb` passes `expectedAccount` (the account's linked address) into `tmWalletOp` (`app/views/contests/new.html.erb:472`), forwarded by the runner (`app/views/shared/_wallet_op_runner.html.erb:300`) to solana-studio's `walletOps.run`, which refuses a different connected wallet before anything is signed. That is a UX guard, not the ownership proof — the on-chain program binds the creator. On the ENTRY path both contest boards declare the same `expectedAccount` through the same runner, and the proof is server-side: `Solana::Vault#cosign_expectation` (`app/services/solana/vault.rb:3436-3457`) reads the cosigner off the wire the server stored for this entry and re-asserts it against the session's wallet (`:3449-3450`), and `Solana::Cosign::Expectation#verify!` refuses a wire whose signer set does not match, so a wallet swap fails server-side instead.
- **Insufficient USDC for prize pool** — `ContestsController#onchain_create_precheck` calls `#insufficient_usdc_error` (`app/controllers/contests_controller.rb:2350`, defined at `:2393-2433`); the client modal offers a "Mint $500 Test USDC" recovery button from `showInsufficientUsdcModal` (`app/views/contests/new.html.erb:372-381`) which hits `POST /faucet` from `mintTestUsdcAndRetry` (`:383-408`). `FaucetController#claim` is production-disabled per OPSEC-020 (`app/controllers/faucet_controller.rb:32`).
- **On-chain Contest PDA already exists** — `ContestsController#onchain_create_precheck` refuses (`app/controllers/contests_controller.rb:2338-2344`). Common after a finalize that broadcast successfully but failed at `verify_solana_transaction!` — which now leaves a `pending` DB row carrying the PDA and the signature, saved by `ContestsController#finalize` (`:450-465`), so the stranded contest is findable rather than invisible. `PendingContestReconcilerJob#perform` (`app/jobs/pending_contest_reconciler_job.rb:16-19`) sweeps stranded `pending` rows every 15 minutes (`config/schedule.yml:120-132`) with a read-only existence check of the derived PDA — present → `open`, absent → the squatting row is deleted — but a row that already carries a broadcast signature is flagged for a human rather than healed, so this exact case still needs the admin to pick a different slug or resolve the row by hand.
- **No active season** — `ContestsController#enter` refuses: `Entries::ManagedEntry#call` raises (`app/services/entries/managed_entry.rb:88-93`). User-visible alert: "No active season configured. Set one at /admin/seasons before users can enter on-chain contests." → the admin loops back to 2b.
- **Sign-then-refresh during entry** — the `PendingTransaction` is left `pending` or `submitted`. The board polls `POST /contests/:id/recover_pending_entry` (`ContestsController#recover_pending_entry` — `app/controllers/contests_controller.rb:1237-1335`), which either promotes the entry, keeps polling, or fails and releases it.
- **IDL hash drift after a turf-vault upgrade** — `Solana::Config.verify_idl!` refuses to boot and to precompile in production (`docs/SOLANA.md:632`). Borsh decoding would silently corrupt every account read otherwise. The operator must re-pin `EXPECTED_IDL_HASH` from the freshly **built** IDL — NOT `anchor idl fetch`, which returns the stale pre-upgrade IDL because a Squad upgrade runs only the BPF `upgrade` instruction (`docs/SOLANA.md:603`) — before pushing. See the `feedback_post_deploy_idl_pin` memory.
- **Session token mismatch** — `ApplicationController#verify_session_token` (`app/controllers/application_controller.rb:506-526`) force-logs-out a stale session (OPSEC-045). The admin re-runs step 1.
- **Tx fails `Solana::TxVerifier`** — `ContestsController#verify_solana_transaction!` re-raises the message (`app/controllers/contests_controller.rb:2591-2592`) and the endpoint returns 422. On the create path the on-chain side is already committed and the `pending` row already holds the signature; the operator inspects via `/admin/outbound_requests` and the Solana explorer.

## Related workflows

- [[web3-landing-to-entry]] — the same Phantom auth and Phantom direct-entry signing path, from a non-admin user landing on `/lp/:slug` instead of `/contests/new`. Steps 1 and 4 above are shared.
- [[email-signup-token-to-chat]] — the managed-wallet alternative: `ContestsController#enter` hands the entry to `Entries::ManagedEntry#fund!` (`app/services/entries/managed_entry.rb:151-230`), which consumes an `EntryTokenAccount` PDA through `Solana::Vault#enter_contest_with_token` (`:177`) instead of charging USDC. An admin never hits this branch — `ContestsController#enter` refuses an `onchain_session?` request before it gets there (`app/controllers/contests_controller.rb:834-840`).
- [[referral-google-tokens-to-chat]] — the Google OAuth signup path; it lands the user in the same `enter` action with a managed wallet, taking the token-consume branch.
- [[slate-build]] — the predecessor for NFL contests. A contest is opened on a Slate, and `ContestsController#resolve_span_slate` builds or reuses the span slate via `Nfl::BuildSpanSlate.call` (`app/controllers/contests_controller.rb:2172`). That slate's frozen `turf_score` is what settlement multiplies by, so it must not be rebuilt after picks land.

<!-- citation-guard: enforced -->
