# Workflow: admin-contest-setup

> **Code is law.** Every claim below cites `path/to/file.rb:NN` from the current
> codebase, and a bare `:NN` inherits the nearest preceding path — file context
> resets at each `##` heading. The number is bookkeeping; the SYMBOL beside it is
> the claim, and `test/docs/workflow_citation_docs_test.rb` reddens when a
> citation stops landing inside the definition its prose names.
> That symbol check reaches **187 of the 230 citations** here. The other **43**
> sit in code with no enclosing definition the guard can derive: six
> `config/routes.rb` entries, one `config/schedule.yml` job, ERB markup and form
> fields, class-body `before_action` / `include` / `after_create` declarations, two
> constants, and two lines of `docs/SOLANA.md` prose. Those ride the weaker LITERAL
> fallback: it proves the words the prose quotes are present in the cited lines, not
> that the code is. **All 14 citations on `app/views/layouts/application.html.erb`
> and `app/views/shared/_contest_create_intent.html.erb`** — the Phantom SIWS
> surface and the contest-create signing intent, i.e. every wallet-facing claim in
> this document — are in that 43, and the cause is mechanical rather than editorial:
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
- Admin has `role == "admin"` (`User#admin?` — `app/models/user.rb:263-265`) and a linked Phantom wallet (`web3_solana_address`). Admins are web3-only by policy — `User#generate_managed_wallet!` early-returns for admins (`app/models/user.rb:586`, OPSEC-044).
- `EXPECTED_IDL_HASH` matches `config/turf_vault.idl.json` (verified at boot — `Solana::Config.verify_idl!`, `app/services/solana/config.rb`).
- An active `SeasonConfig.current_season_id` exists. Without it, `ContestsController#enter` raises before any consume (`app/controllers/contests_controller.rb:878-880`).

## Sequence

### 1. Admin logs in via Phantom (SIWS)

1. **Click "Connect Wallet"** — the multi-wallet picker modal (solana-studio's `solana_studio/modals/_wallet_connect`, mounted from `app/views/layouts/application.html.erb` with `wallet_connect_modal_locals`) invokes the inline `window.solanaConnectAndVerify` SIWS helper (`app/views/layouts/application.html.erb:353`). Alpine `x-data` factory functions must be inline because `importmap` modules load *after* Alpine processes `x-data` (`app/views/layouts/application.html.erb:1513-1515`).
2. **`GET /auth/solana/nonce`** — `SolanaSessionsController#nonce` (`app/controllers/solana_sessions_controller.rb:5-9`). Stores `session[:solana_nonce]` + `session[:solana_nonce_at]`.
   - Route: `solana_sessions#nonce` (`config/routes.rb:191`).
3. **Client builds the SIWS message** and calls `provider.signMessage(...)` — `app/views/layouts/application.html.erb:557-558`. The helper prefers the wallet's own `signIn` and falls back to `connect` + `signMessage`, announcing the fallback with a `console.warn` at `:532`. The message body begins `wants you to sign in with your Solana account` (`:557`), and the nonce echoed back is checked against `nonceData.nonce` (`:497`).
   - Message format: `"<host> wants you to sign in with your Solana account:\n<pubkey>\n\n<userIdLine>Sign in to Turf Monster\n\nNonce: <nonce>"`. The opening `<host>` token is the OPSEC-018 host binding the server later asserts. `<userIdLine>` is empty at login (no `current_user` yet) and only present when re-signing inside an authenticated session (OPSEC-005 — see step 4).
4. **`POST /auth/solana/verify`** — `SolanaSessionsController#verify` (`app/controllers/solana_sessions_controller.rb:25-103`), routed as `solana_sessions#verify` (`config/routes.rb:192`).
   - `verify_solana_signature!` (`app/controllers/solana_sessions_controller.rb:26`) deletes the nonce before verifying (replay protection) and delegates to `Solana::AuthVerifier.verify!` in the solana-studio gem with `expected_host: request.host_with_port`. The method is `Solana::SessionAuth#verify_solana_signature!`, which lives in **studio-engine** (`studio-engine: app/controllers/concerns/solana/session_auth.rb` — it deletes the nonce before verifying and binds the OPSEC-005 `User-ID:` line) and is mixed in via `include Solana::SessionAuth` (`app/controllers/solana_sessions_controller.rb:2`, `app/controllers/accounts_controller.rb:3`, `app/controllers/entries_controller.rb:2`). `ContestsController` no longer includes it: `#enter`'s signature branch was the controller's only caller and it now refuses a web3 session outright.
   - Looks up the user by wallet with `User.from_solana_wallet(pubkey_b58)` (`app/models/user.rb:236-238`) — a plain `find_by`, no create. `SolanaSessionsController#verify` is what builds the row when the lookup misses (`app/controllers/solana_sessions_controller.rb:53`).
   - `set_app_session(user)` at `:63` (`app/controllers/application_controller.rb:33-47`) writes the session-token cookie and explicitly **clears** any stale `session[:onchain]` flag (`session.delete(:onchain)` — `app/controllers/application_controller.rb:39`). `SolanaSessionsController#verify` then re-grants it through `promote_to_onchain_session!` (`app/controllers/solana_sessions_controller.rb:77`), because this auth path is a genuine Phantom signature.
5. **Admin gate** — every admin route runs the class-body `before_action :require_admin` (`app/controllers/contests_controller.rb:15`). The helper is `Studio::ErrorHandling#require_admin` in `studio-engine` (`studio-engine: app/controllers/concerns/studio/error_handling.rb`), which redirects with "Not authorized" unless `logged_in? && current_user.admin?`.

### 2. Initialize on-chain accounts — **conditional**

The `if needed` branch in the user's mental model maps to three distinct chain-init paths. Only the first is rare; the other two run silently on demand.

#### 2a. One-time vault init (rare — once per program ID)

Surfaced from the admin Link Hub as **"Vault Init"** when the vault is uninitialized, and from the Vault State page when an operator needs the direct init path:

- Visibility check: `Admin::VaultInitController.vault_uninitialized?` (`app/controllers/admin/vault_init_controller.rb:124-130`) — it calls `Solana::Vault#read_vault_state` (`app/services/solana/vault.rb:548-599`) and caches the boolean. `Admin::VaultInitController#confirm` busts that cache on success (`app/controllers/admin/vault_init_controller.rb:104`).
- Both entry points link to `admin_vault_init_path` — the Link Hub tile (`app/views/admin/hub.html.erb:55`) and the Vault State fallback link (`app/views/admin/vault_state/show.html.erb:13`).
- Routes: `config/routes.rb:552-554` — `vault_init#show`, `vault_init#build`, `vault_init#confirm`.
- Flow:
  1. `Admin::VaultInitController#build` (`app/controllers/admin/vault_init_controller.rb:64-86`) refuses an already-initialized vault (`:66`), runs `Admin::VaultInitController#validate_init_params!` (`:138-159` — three distinct signers `:149`, threshold 1-3 `:150`, creator must be one of the signers `:151` and must equal `INIT_AUTHORITY` on mainnet `:156-157`), then calls `Solana::Vault#build_initialize_vault` (`app/services/solana/vault.rb:449-480`). The bot fee-pays; the creator slot is left for Phantom.
  2. Phantom cosigns + broadcasts client-side. This is the one flow in this document where the browser still broadcasts.
  3. `Admin::VaultInitController#confirm` (`app/controllers/admin/vault_init_controller.rb:88-112`) verifies the TX with `Solana::TxVerifier.verify!` (`:97`) against the `initialize` discriminator, the vault PDA as writable, and the creator as signer, then deletes the cache key (`:104`).
- **Today's reality:** live devnet/mainnet program identity is canonical in `/Users/alex/projects/turf-vault/docs/CURRENT_DEPLOYMENT.md`. The admin will not see Vault Init on an already-initialized program; this branch only fires the first time the app points at a fresh program ID.

#### 2b. Per-season seed-schedule init (rare — once per Season)

`ContestsController#enter` raises **"No active season configured. Set one at /admin/seasons before users can enter on-chain contests."** when `SeasonConfig.current_season_id.to_i.zero?` (`app/controllers/contests_controller.rb:878-880`), inside its `with_lock` and before any consume. Step 4 fails loudly if step 2b was skipped. Contest *creation* has its own parallel guard: `ContestsController#onchain_season_error` (`:2449-2466`) returns "…before creating on-chain contests." and `#ensure_onchain_season_ready!` (`:2443-2447`) raises it.

- Admin UI: `Admin::SeasonsController#create` (`app/controllers/admin/seasons_controller.rb:11-39`) reads `name`, `season_id`, and `slot_0..slot_4` from the form (`:14`), validates the five slots (`:22`), calls `Solana::Vault#create_season(season_id:, name:, schedule:)` (`:31`, definition `app/services/solana/vault.rb:1973-2013`), and — when `params[:set_current] == "1"` — flips `SeasonConfig.set_current!(season_id)` (`app/controllers/admin/seasons_controller.rb:32`).
- Routes: `seasons#create` and `seasons#set_current` (`config/routes.rb:565-567`).
- The on-chain `Season` PDA lives at `[b"season", season_id_le]` — derived by `Solana::Vault#season_pda` (`app/services/solana/vault.rb:259-262`) — and stores the `seed_schedule` (default `[25, 19, 14, 10, 7]`) the `enter_contest` instruction reads to award seeds (see `docs/SOLANA.md`).

#### 2c. Per-contest Contest PDA init — **fires every time** in step 3

The contest PDA at `[b"contest", sha256(slug)]`, derived by `Solana::Vault#contest_pda` (`app/services/solana/vault.rb:181-184`), is created by the `create_contest` instruction in step 3 below. There is no separate "init contract" click for this.

#### 2d. Per-user UserAccount PDA — fires lazily on first entry

`Solana::Vault#ensure_user_account` (`app/services/solana/vault.rb:728-737`) is called inline by every entry path — `ContestsController#prepare_entry` calls it at `app/controllers/contests_controller.rb:1069` (step 4). It checks the PDA size and either no-ops, creates the PDA via `Solana::Vault#create_user_account` (`app/services/solana/vault.rb:739-771`), or raises on schema drift. For most admins this is a no-op, because the class-body `after_commit :enqueue_onchain_account_setup, on: :create` (`app/models/user.rb:127`) already ran `User#enqueue_onchain_account_setup` (`:793-795`) at signup, enqueuing `CreateOnchainUserAccountJob` (`app/jobs/create_onchain_user_account_job.rb`; see `docs/AUTH.md`).

### 3. Admin creates a contest

Phantom-driven, four server round-trips. **The DB row is written BEFORE the money moves**, deliberately: `finalize` saves a `pending` contest carrying the derived PDA, broadcasts, records the signature, and only then verifies and promotes the row to `open`. A broadcast that succeeds while a later step fails therefore leaves a `pending` row an operator can find — not a funded PDA with nothing pointing at it.

1. **`GET /contests/new`** — `ContestsController#new` (`app/controllers/contests_controller.rb:83-99`). The form lives at `app/views/contests/new.html.erb`: the `f.collection_select :slate_id` slate picker at `app/views/contests/new.html.erb:84-86`, the `contest[week_span]` select at `:93-95`, `contest_type` at `:123-125`, the hidden `contest_starts_at` **Starts At** field at `:152-153`, and `contest_image` at `:260`. `contest_type` must be one of `Contest.selectable_formats` (`app/models/contest.rb:338-340`; it respects the `ENABLE_TEST_SCAFFOLDING` flag via `AppFlags.test_scaffolding?`). The visible field is **Starts At**, defaulted from the selected slate's first game kickoff by `ContestsController#default_start_for_slate` (`app/controllers/contests_controller.rb:2819-2821`); `Contest#starts_in_at` (`app/models/contest.rb:733-735`) is what the countdown and the on-chain lock timestamp use. `entry_fee_cents` + `max_entries` are derived server-side from `Contest#format_config` (`:349-351`) inside `ContestsController#build_unpersisted_contest_from_params` (`app/controllers/contests_controller.rb:2211-2225`, at `:2214-2215`).
   - **Slate span (slates-sport-year):** the operator may extend a single slate into a **multi-week span** with the `week_span` field. `ContestsController#resolve_span_slate` (`app/controllers/contests_controller.rb:2236-2266`) turns "N weeks from this anchor" into the ONE span slate the contest is played on, building it with `Nfl::BuildSpanSlate.call` if needed (`:2262`). The span is scoped to the anchor slate's season through the **`slates.year` column**, read via `Slate#season_year` (`:2248`), and to its `season_type` (`:2262`) so a preseason anchor cannot yield regular-season weeks. A refusal is captured in `@span_slate_error` (`:2264`) and `ContestsController#create` renders it rather than silently building a shorter contest (`:277-279`). Slate classification reads the **`slates.sport` column** via `Slate#sport`, surfaced by `ContestsController#sport_for_slate` (`:2831-2833`); selectable slates come from `#contest_slate_options` (`:2813-2817`). A span of 1 leaves the plain `slate_id` select untouched (`:2238`).
2. **Submit → `POST /contests`** — `ContestsController#create` (`app/controllers/contests_controller.rb:267-310`):
   - Refuses non-Phantom callers (`:268`).
   - `ContestsController#onchain_create_precheck` (`:2407-2441`, called at `:287`) — model validation (`:2412`), slug uniqueness in the DB via `#slug_taken_message` (`:2422`, definition `:2173-2181`), the on-chain Contest PDA must not already exist (`:2427-2434`), season readiness through `#onchain_season_error` (`:2436`), then `ContestsController#insufficient_usdc_error` (`:2483-2523`, called at `:2440`) verifies the creator's ATA balance covers `guaranteed_prize_cents`.
   - `Solana::Vault#build_create_contest` (`app/services/solana/vault.rb:875-916`, called at `app/controllers/contests_controller.rb:292`) builds a fully UNSIGNED `create_contest` TX with `admin_signs: false` (`:296`) — the admin fee-payer and creator signature slots are both left empty. The account layout is assembled in `Solana::Vault#create_contest_instruction` (`app/services/solana/vault.rb:918-960`): payer, creator, vault_state, contest (init), USDC mint, creator_ata, vault_usdc, token program, system program.
   - The server returns `{ serialized_tx, contest_pda, slug, params_token }` (`app/controllers/contests_controller.rb:299-305`). The `params_token` is a `Rails.application.message_verifier` blob with a 10-minute TTL (`ONCHAIN_CREATE_TOKEN_TTL` — `:265`; signed in `ContestsController#sign_onchain_create_payload`, `:2532-2556`) so the server can trust the re-posted form fields in step 3.4 without re-validating them. The banner image rides this PREPARE post, not finalize: `ContestsController#stash_contest_banner` (`:2360-2373`) uploads it as an unattached blob, and its signed id is bound into the token as `contest_image_id` (`:2534`). It has to leave the browser here, because on the redirect transport the page is destroyed while the wallet signs and finalize runs on a document that never held the file input.
3. **Refresh blockhash + wallet SIGN (no client broadcast)** — the form makes ONE call, `window.tmWalletOp('contest_create', …)` (`app/views/contests/new.html.erb:462-476`), and the `contest_create` intent registered by name from `app/views/shared/_contest_create_intent.html.erb:25-29` does the rest on every transport, injected or redirect. Its prepare half, `tmPrepareContestCreate` (`:53-93`), POSTs the whole form as `new FormData(form)` — banner included — to `POST /contests` (`:62-66`), then calls `POST /contests/rebuild_create_tx` to re-issue the unsigned TX over a fresh blockhash (`:77-81`); that is `ContestsController#rebuild_create_tx` (`app/controllers/contests_controller.rb:322-349`, routed by `post :rebuild_create_tx` at `config/routes.rb:300`), and the re-issue goes through the server so the exact message bytes stay bound to the signed `params_token` (`app/controllers/contests_controller.rb:323-336`). The wallet then signs ONLY — the intent is declared `signOnly: true` (`app/views/shared/_contest_create_intent.html.erb:26`) — and the complete half, `tmCompleteContestCreate` (`:98-137`), refuses a wallet that broadcast instead of signing — no `result.signedTransaction` means no bytes for the server to cosign (`:99-102`) and POSTs the signed-but-unbroadcast wire as `signed_tx` to `/contests/finalize` (`:122-130`). There is no `connection.sendRawTransaction` on this path: the browser never touches the RPC.
4. **`POST /contests/finalize`** — `ContestsController#finalize` (`app/controllers/contests_controller.rb:381-487`). Collection route (no `:id`), `post :finalize` at `config/routes.rb:301`. In order:
   - `ContestsController#verify_onchain_create_payload` (`app/controllers/contests_controller.rb:2558-2562`) decodes the `params_token` (`:382`) and the user is re-checked against it (`:383`).
   - `Solana::Vault#contest_pda(slug)` (`app/services/solana/vault.rb:181-184`) re-derives the PDA and `finalize` demands `params[:contest_pda]` match (`app/controllers/contests_controller.rb:385-386`).
   - `Solana::Vault#assert_create_contest_cosign_safe!` (`app/services/solana/vault.rb:2311-2394`, called at `app/controllers/contests_controller.rb:402-407`) inspects the signed wire before the server will put its own signature on it.
   - **Write-ahead row.** `ContestsController#build_pending_contest` (`:2308-2346`) constructs the row at `status: :pending` carrying `onchain_contest_id` (`:2320-2322`) and with `skip_onchain_callback = true` (`:2345`) so the legacy `after_create :create_onchain_with_rollback!` hook (`app/models/contest.rb:125`) cannot double-spend. `finalize` saves it at `app/controllers/contests_controller.rb:415`, **before** a lamport moves. `Contest`'s `before_create` binds `season_id` to `SeasonConfig.current_season_id` (`app/models/contest.rb:131`).
   - `Solana::Vault#cosign_and_broadcast_create_contest` (`app/services/solana/vault.rb:2443-2454`) cosigns and broadcasts (`app/controllers/contests_controller.rb:419`). Past this line the money is real.
   - The signature is recorded IMMEDIATELY (`:425`), before any read-back that can raise — the only off-chain evidence tying this request to the on-chain effect.
   - `ContestsController#verify_solana_transaction!` (`:2599-2608`, called at `:444-449`) → `Solana::TxVerifier.verify!` (OPSEC-010) asserts the broadcast TX is the `create_contest` instruction signed by `creator_pubkey` and writing to the derived PDA.
   - Only then is the row promoted to `open` (`:452`), the banner attached last from the stashed blob id the token carries (`:460`) — `ContestsController#attach_contest_banner` (`:2392-2402`) logs rather than raises, so it cannot fail a funded contest — and `{ success: true, redirect: contest_path(contest), slug: }` returned (`:462`).

> **Fallback path — server-funded.** `Contest#create_onchain!` (`app/models/contest.rb:364-387`), wired via the class-body `after_create :create_onchain_with_rollback!` (`:125`, method at `:396-402`), calls `Solana::Vault#create_contest_server_funded` (`app/services/solana/vault.rb:965-1024`). The admin signs as both payer and creator, with prize-pool USDC funded from the configured server/admin wallet. It is used for Rails console and scripts, and auto-skipped in tests and for any contest already on-chain — `Contest#skip_onchain_callback_active?` (`app/models/contest.rb:389-391`). The UI does not use this path.

### 4. Admin enters their own contest

Admins follow the **same** path as any other Phantom-authenticated user — there is no admin-only shortcut. The `comped: true` escape hatch on `Entry#assert_enterable!` (`app/models/entry.rb:125-136`) and `Entry#confirm!` (`:170-187`) is used **only** by `Contest#fill!` (`app/models/contest.rb:494-534`) for bot-seeded test entries, never by a real admin entering through the UI.

Two-stage hold-to-confirm followed by the Phantom direct-entry signing flow:

1. **Toggle 6 selections** on the matchup board — `POST /contests/:id/toggle_selection` per click (`ContestsController#toggle_selection` — `app/controllers/contests_controller.rb:1481-1502`). Each call `find_or_create_by!`s the cart entry (`:1489`) and toggles a `Selection` row (`:1492`). World Cup Survivor contests use `ContestsController#pick` instead (`:1505-1534`).
2. **Hold-to-confirm** triggers `confirmEntry()` in `app/views/contests/_turf_totals_board.html.erb:1566-2002`:
   - It branches on `useOnchainFlow = sess.isWeb3 && this.contestOnchain` (`:1630`, taken at `:1644`). Admin = web3 = always the on-chain branch.
   - There is no client-side wrong-wallet throw on this path any more; the binding is server-side (see the failure modes below).
3. **`POST /contests/:id/prepare_entry`** — `ContestsController#prepare_entry` (`app/controllers/contests_controller.rb:1001-1156`):
   - Requires `onchain_session?` (`:1024`) — the admin's Phantom-auth session has it from step 1.
   - Requires a verified on-chain contest and a Phantom wallet (`:1045-1046`), refuses a full contest (`:1049`), validates exactly `picks_required` selections (`:1052` — `Contest#picks_required` at `app/models/contest.rb:267-271`, floored on `TURF_TOTALS_DEFAULT_PICKS_REQUIRED = 6` at `:67`), and refuses if any underlying game is `locked?` (`app/controllers/contests_controller.rb:1054`).
   - Assigns `entry.entry_number` by **probing the chain for a free slot** — `Entry#assign_onchain_entry_number!` (`app/models/entry.rb:307-322`, called at `app/controllers/contests_controller.rb:1064`) reads existing DB entry numbers, then asks `Solana::Vault#next_free_entry_index` (`app/services/solana/vault.rb:205-214`) for the first on-chain-free slot.
   - `Solana::Vault#ensure_user_account(current_user.web3_solana_address, username:)` (`app/controllers/contests_controller.rb:1069`) — see 2d above.
   - `Solana::Vault#build_enter_contest(wallet, slug, entry_num, currency_idx:, season_id:)` (`app/services/solana/vault.rb:1300-1364`, called at `app/controllers/contests_controller.rb:1105`) builds the unified `enter_contest` transaction; a prepared entry token takes `Solana::Vault#build_enter_contest_with_token` instead (`:1088`, definition `app/services/solana/vault.rb:1424-1454`). The Phantom-first flow leaves both signature slots empty — `confirm_onchain_entry` validates the user-signed wire before the server cosigns and broadcasts.
   - Persists a `PendingTransaction` with `tx_type: "enter_contest"`, `status: "pending"` and polymorphic `target: entry` (`app/controllers/contests_controller.rb:1120-1132`), so a mid-flight refresh leaves a recoverable trail.
   - Returns `{ serialized_tx, entry_id, entry_pda, ptx_slug, token_funded, currency }` (`:1135-1152`) — `currency` echoes the server's own pricing decision so the sign card can never name a different token than the transfer it asks for (`:1151`).
4. **Phantom signs, server broadcasts** — the browser signs the prepared wire and posts it to `confirm_onchain_entry`; the server validates the signed wire, cosigns with the admin key, simulates, broadcasts, stamps the `PendingTransaction`, and verifies the resulting signature.
5. **`POST /contests/:id/confirm_onchain_entry`** — `ContestsController#confirm_onchain_entry` (`app/controllers/contests_controller.rb:1341-1459`):
   - It loads the in-flight `PendingTransaction` (`:1374`), then `Solana::Vault#assert_entry_cosign_safe!` (`app/services/solana/vault.rb:2200-2293`, called at `app/controllers/contests_controller.rb:1388`) refuses to cosign a wire that is not exactly one `enter_contest` instruction binding the session's wallet to the derived entry PDA.
   - `Solana::Vault#cosign_and_broadcast_entry` (`app/services/solana/vault.rb:2400-2420`) cosigns and broadcasts (`app/controllers/contests_controller.rb:1397`); the signature is stamped onto the `PendingTransaction` immediately (`:1409`), because it is on-chain whether or not the steps below raise.
   - `ContestsController#verify_and_confirm_onchain_entry!` (`:2656-2672`, called at `:1415-1418` with the client-supplied `params[:entry_pda]`) re-derives `entry_pda` via `Solana::Vault#entry_pda(slug, wallet, entry_number)` (`app/controllers/contests_controller.rb:2658-2660`, definition `app/services/solana/vault.rb:186-191`) and rejects a mismatched client-supplied PDA (`app/controllers/contests_controller.rb:2661`).
   - `#verify_and_confirm_onchain_entry!` then calls `verify_solana_transaction!` (`:2663-2668`), asserting the TX is `enter_contest` signed by the user's wallet and writing to the derived entry PDA (OPSEC-010).
   - `Entry#confirm_onchain!` (`app/models/entry.rb:242-272`) promotes the entry to `active` and stamps `onchain_tx_signature` + `onchain_entry_id`. The `comped:` flag is NOT passed — the on-chain path is user-initiated only, and the on-chain TX itself is the payment proof (`:247-248`).
   - The `PendingTransaction` is marked `confirmed` (`app/controllers/contests_controller.rb:1420`) and the response carries `{ success: true, redirect, tx_signature, seeds_earned, seeds_total, seeds_level }` (`:1437-1444`).

## Data touched

- **DB:**
  - `users` (read — `User.from_solana_wallet` at `app/models/user.rb:236-238`; insert in `SolanaSessionsController#verify` at `app/controllers/solana_sessions_controller.rb:53` on first login for this pubkey)
  - `season_configs` (read — `SeasonConfig.current_season_id`, `app/models/season_config.rb:21-23`)
  - `slates` (read — the selected slate; on a span, its consecutive weekly siblings, scoped by the `year`/`sport`/`season_type` columns in `ContestsController#resolve_span_slate` → `Nfl::BuildSpanSlate` — `app/controllers/contests_controller.rb:2262`)
  - `slate_matchups` (read — the pickable matchups behind the selections)
  - `contests` (insert at `status: :pending` in `ContestsController#finalize` — `app/controllers/contests_controller.rb:415` — then `onchain_tx_signature` at `:425` and promotion to `open` at `:452`)
  - `entries` (insert via `ContestsController#toggle_selection` at `:1489`; update to `active` via `Entry#confirm_onchain!` at `app/models/entry.rb:242-272`)
  - `selections` (insert per matchup toggle, inside `Entry#toggle_selection!` — `app/models/entry.rb:54`)
  - `pending_transactions` (insert in `ContestsController#prepare_entry` at `app/controllers/contests_controller.rb:1120`; `tx_signature` + `status` updated through the lifecycle by `ContestsController#confirm_onchain_entry` at `:1409` and `:1420`)
  - `transaction_logs` (an audit row written by `Entry#confirm!` when the entry fee is positive — `app/models/entry.rb:189-191`; that is the off-chain `confirm!` path, not the on-chain admin path in step 4)
  - `outbound_requests` (insert per Solana RPC call via `Solana::ClientLogger`)
- **On-chain (turf-vault):**
  - `VaultState` PDA at `[b"vault"]` — `Solana::Vault#vault_state_pda` (`app/services/solana/vault.rb:172-174`); read, and **init** if 2a fires
  - `Season` PDA at `[b"season", season_id_le]` — `Solana::Vault#season_pda` (`:259-262`); read, and **init** if 2b fires
  - `UserAccount` PDA at `[b"user", wallet]` — `Solana::Vault#user_account_pda` (`:176-179`); read, and **init** if 2d fires
  - `Contest` PDA at `[b"contest", sha256(slug)]` — `Solana::Vault#contest_pda` (`:181-184`); **init** via the `create_contest` IX in step 3
  - `ContestEntry` PDA at `[b"entry", contest_pda, wallet, entry_num_le]` — `Solana::Vault#entry_pda` (`:186-191`); **init** via the `enter_contest` IX in step 4
  - SPL token transfers: creator ATA → per-contest prize-pool ATA for the prize pool (step 3); user ATA → per-currency operator-revenue ATA for the entry fee (step 4)
- **External:** Solana RPC. Every `build_*` re-derives its PDAs, and both money paths broadcast SERVER-side after the admin cosign — `Solana::Vault#cosign_and_broadcast_create_contest` (`app/services/solana/vault.rb:2443-2454`) and `#cosign_and_broadcast_entry` (`:2400-2420`). Only the 2a vault init still broadcasts from the browser.

## Failure modes

- **Wrong wallet connected** — on the CREATION form, `new.html.erb` passes `expectedAccount` (the account's linked address) into `tmWalletOp` (`app/views/contests/new.html.erb:472`), forwarded by the runner (`app/views/shared/_wallet_op_runner.html.erb:190`) to solana-studio's `walletOps.run`, which refuses a different connected wallet before anything is signed. That is a UX guard, not the ownership proof — the on-chain program binds the creator. On the ENTRY path there is no client-side equivalent; `Solana::Vault#assert_entry_cosign_safe!` (`app/services/solana/vault.rb:2200-2293`) derives the expected entry PDA from the session's wallet (`:2223`) and refuses to cosign a wire that does not match, so a wallet swap fails server-side instead.
- **Insufficient USDC for prize pool** — `ContestsController#onchain_create_precheck` calls `#insufficient_usdc_error` (`app/controllers/contests_controller.rb:2440`, defined at `:2483-2523`); the client modal offers a "Mint $500 Test USDC" recovery button from `showInsufficientUsdcModal` (`app/views/contests/new.html.erb:372-381`) which hits `POST /faucet` from `mintTestUsdcAndRetry` (`:383-408`). `FaucetController#claim` is production-disabled per OPSEC-020 (`app/controllers/faucet_controller.rb:32`).
- **On-chain Contest PDA already exists** — `ContestsController#onchain_create_precheck` refuses (`app/controllers/contests_controller.rb:2427-2434`). Common after a finalize that broadcast successfully but failed at `verify_solana_transaction!` — which now leaves a `pending` DB row carrying the PDA and the signature, saved by `ContestsController#finalize` (`:414-425`), so the stranded contest is findable rather than invisible. `PendingContestReconcilerJob#perform` (`app/jobs/pending_contest_reconciler_job.rb:16-19`) sweeps stranded `pending` rows every 15 minutes (`config/schedule.yml:73-84`) with a read-only existence check of the derived PDA — present → `open`, absent → the squatting row is deleted — but a row that already carries a broadcast signature is flagged for a human rather than healed, so this exact case still needs the admin to pick a different slug or resolve the row by hand.
- **No active season** — `ContestsController#enter` raises (`app/controllers/contests_controller.rb:878-880`). User-visible alert: "No active season configured. Set one at /admin/seasons before users can enter on-chain contests." → the admin loops back to 2b.
- **Sign-then-refresh during entry** — the `PendingTransaction` is left `pending` or `submitted`. The board polls `POST /contests/:id/recover_pending_entry` (`ContestsController#recover_pending_entry` — `app/controllers/contests_controller.rb:1230-1328`), which either promotes the entry, keeps polling, or fails and releases it.
- **IDL hash drift after a turf-vault upgrade** — `Solana::Config.verify_idl!` refuses to boot and to precompile in production (`docs/SOLANA.md:149`). Borsh decoding would silently corrupt every account read otherwise. The operator must re-pin `EXPECTED_IDL_HASH` from the freshly **built** IDL — NOT `anchor idl fetch`, which returns the stale pre-upgrade IDL because a Squad upgrade runs only the BPF `upgrade` instruction (`docs/SOLANA.md:131`) — before pushing. See the `feedback_post_deploy_idl_pin` memory.
- **Session token mismatch** — `ApplicationController#verify_session_token` (`app/controllers/application_controller.rb:467-487`) force-logs-out a stale session (OPSEC-045). The admin re-runs step 1.
- **Tx fails `Solana::TxVerifier`** — `ContestsController#verify_solana_transaction!` re-raises the message (`app/controllers/contests_controller.rb:2606-2607`) and the endpoint returns 422. On the create path the on-chain side is already committed and the `pending` row already holds the signature; the operator inspects via `/admin/outbound_requests` and the Solana explorer.

## Related workflows

- [[web3-landing-to-entry]] — the same Phantom auth and Phantom direct-entry signing path, from a non-admin user landing on `/lp/:slug` instead of `/contests/new`. Steps 1 and 4 above are shared.
- [[email-signup-token-to-chat]] — the managed-wallet alternative: `ContestsController#enter` falls through to `#resolve_web2_entry_funding!` (`app/controllers/contests_controller.rb:1878-1950`), which consumes an `EntryTokenAccount` PDA through `Solana::Vault#enter_contest_with_token` (`:1898`) instead of charging USDC. An admin never hits this branch — `#enter` routes it only for a non-`onchain_session?` request (`:891`).
- [[referral-google-tokens-to-chat]] — the Google OAuth signup path; it lands the user in the same `enter` action with a managed wallet, taking the token-consume branch.
- [[slate-build]] — the predecessor for NFL contests. A contest is opened on a Slate, and `ContestsController#resolve_span_slate` builds or reuses the span slate via `Nfl::BuildSpanSlate.call` (`app/controllers/contests_controller.rb:2262`). That slate's frozen `turf_score` is what settlement multiplies by, so it must not be rebuilt after picks land.
