# Workflow: admin-contest-setup

> **Code is law.** Every claim below cites `path/to/file.rb:NN` from the current
> codebase. Re-verify on edit — line numbers drift on refactor.
>
> **Refresh status:** Fully re-verified against `accepted` on 2026-07-30. Every
> method/file/route/command below was read at the cited line. Two structural
> corrections since the last pass: the `Solana::SessionAuth` concern was **lifted
> into studio-engine** (it no longer lives in turf-monster), and the create flow
> now supports **multi-week span contests** keyed off the `slates.sport` /
> `slates.year` columns added by `slates-sport-year` (#246).

**Trigger:** Operator (admin) opens the app to spin up a brand-new on-chain contest and enter it themselves.
**Actors:** Admin (Phantom wallet) / Phantom / Rails / Solana RPC / turf-vault Anchor program / Squads (only if the vault has never been initialized on this program).
**Outcome:** New on-chain `Contest` PDA funded with the prize pool; matching DB `Contest` row; admin's `Entry` PDA created + DB entry `active`; admin's `UserAccount` PDA seeded.
**Preconditions:**
- Admin has `role == "admin"` (`User#admin?` — `app/models/user.rb:204-206`) and a linked Phantom wallet (`web3_solana_address`). Admins are web3-only by policy — `User#generate_managed_wallet!` early-returns for admins (`app/models/user.rb:456-470`, OPSEC-044).
- `EXPECTED_IDL_HASH` matches `config/turf_vault.idl.json` (verified at boot — `Solana::Config.verify_idl!`, `app/services/solana/config.rb`).
- An active `SeasonConfig.current_season_id` exists. Without it, `ContestsController#enter` aborts (`app/controllers/contests_controller.rb:558-559`).

## Sequence

### 1. Admin logs in via Phantom (SIWS)

1. **Click "Connect Wallet"** — the multi-wallet picker modal (`app/views/layouts/application.html.erb:957`) invokes the inline `window.solanaConnectAndVerify(...)` SIWS helper (`app/views/layouts/application.html.erb:210-266`). Alpine `x-data` factory functions must be inline because importmap modules load *after* Alpine processes `x-data` (`app/views/layouts/application.html.erb:770-772`).
2. **`GET /auth/solana/nonce`** — `app/controllers/solana_sessions_controller.rb:5-9`. Stores `session[:solana_nonce]` + `session[:solana_nonce_at]`.
   - Route: `config/routes.rb:141`.
3. **Client builds the SIWS message** and calls `provider.signMessage(...)` — `app/views/layouts/application.html.erb:221-225`.
   - Message format: `"<host> wants you to sign in with your Solana account:\n<pubkey>\n\n<userIdLine>Sign in to Turf Monster\n\nNonce: <nonce>"`. The opening `<host>` token is the OPSEC-018 host binding the server later asserts. `<userIdLine>` is empty at login (no `current_user` yet) and only present when re-signing inside an authenticated session (OPSEC-005 — see step 4).
4. **`POST /auth/solana/verify`** — `app/controllers/solana_sessions_controller.rb:25-75`.
   - `verify_solana_signature!` deletes the nonce before verifying (replay protection) and delegates to `Solana::AuthVerifier.verify!` in the solana-studio gem with `expected_host: request.host_with_port`. The method is `Solana::SessionAuth#verify_solana_signature!`, which lives in **studio-engine** (`studio-engine app/controllers/concerns/solana/session_auth.rb:26-53`; nonce delete-before-verify at :39-40, OPSEC-005 `User-ID:` binding at :33-36) and is mixed in via `include Solana::SessionAuth` (`app/controllers/contests_controller.rb:2`, `app/controllers/solana_sessions_controller.rb:2`, `app/controllers/accounts_controller.rb:3`, `app/controllers/entries_controller.rb:2`).
   - Looks up the user by wallet via `User.from_solana_wallet(pubkey_b58)` (`app/models/user.rb:177-190`); creates a new `User` if none exists.
   - `set_app_session(user)` (`app/controllers/application_controller.rb:30-45`) writes the session-token cookie and explicitly **clears** any stale `session[:onchain]` flag (`session.delete(:onchain)` — `app/controllers/application_controller.rb:39`), then `session[:onchain] = true` is re-granted (`app/controllers/solana_sessions_controller.rb:57`) because this auth path is a genuine Phantom signature.
5. **Admin gate** — every admin route runs `before_action :require_admin` (`app/controllers/contests_controller.rb:6`). The helper is `Studio::ErrorHandling#require_admin` in `studio-engine` (`studio-engine app/controllers/concerns/studio/error_handling.rb:170-171`), which redirects with "Not authorized" unless `logged_in? && current_user.admin?`.

### 2. Initialize on-chain accounts — **conditional**

The `if needed` branch in the user's mental model maps to three distinct chain-init paths. Only the first is rare; the other two run silently on demand.

#### 2a. One-time vault init (rare — once per program ID)

Surfaced from the admin Link Hub as **"Vault Init"** when the vault is uninitialized, and from the Vault State page when an operator needs the direct init path:

- Visibility check: `Admin::VaultInitController.vault_uninitialized?` (`app/controllers/admin/vault_init_controller.rb:96-103`) — calls `Solana::Vault#read_vault_state` (`app/services/solana/vault.rb:510-563`) and caches the boolean for 1 hour. Bust on successful confirm.
- Link Hub tile: `app/views/admin/hub.html.erb`. Vault State fallback link: `app/views/admin/vault_state/show.html.erb`.
- Routes: `config/routes.rb:450-452` — `GET admin/vault_init`, `POST admin/vault_init/build`, `POST admin/vault_init/confirm`.
- Flow:
  1. `Admin::VaultInitController#build` (`app/controllers/admin/vault_init_controller.rb:36-59`) validates params (`validate_init_params!` lines 110-131 — three distinct signers, threshold 1-3, creator must equal `INIT_AUTHORITY` on mainnet — `app/controllers/admin/vault_init_controller.rb:128-129`) and calls `Solana::Vault#build_initialize_vault` (`app/services/solana/vault.rb:411-446`). Bot fee-pays; the creator slot is left for Phantom.
  2. Phantom cosigns + broadcasts client-side.
  3. `Admin::VaultInitController#confirm` (`app/controllers/admin/vault_init_controller.rb:60-95`) verifies the TX via `Solana::TxVerifier.verify!` against the `initialize` discriminator + the vault PDA as writable + the creator as signer, then busts the `uninitialized?` cache.
- **Today's reality:** live devnet/mainnet program identity is canonical in `/Users/alex/projects/turf-vault/docs/CURRENT_DEPLOYMENT.md`. The admin will not see Vault Init on an already-initialized program; this branch only fires the first time the app points at a fresh program ID.

#### 2b. Per-season seed-schedule init (rare — once per Season)

`ContestsController#enter` (`app/controllers/contests_controller.rb:558-559`) raises **"No active season configured. Set one at /admin/seasons before users can enter on-chain contests."** when `SeasonConfig.current_season_id.to_i.zero?`. Step 4 will fail loudly if step 2b was skipped. (Contest *creation* has its own parallel guard — `onchain_season_error`, `app/controllers/contests_controller.rb:1803-1820`, message "…before creating on-chain contests.")

- Admin UI: `Admin::SeasonsController#create` (`app/controllers/admin/seasons_controller.rb:11-39`) reads `name`, `season_id`, and `slot_0..slot_4` from the form, calls `Solana::Vault#create_season(season_id:, name:, schedule:)` (`app/services/solana/vault.rb:1845`), and (when `params[:set_current] == "1"`) flips `SeasonConfig.set_current!(season_id)` (`app/controllers/admin/seasons_controller.rb:32`).
- Routes: `config/routes.rb:463-465`.
- The on-chain `Season` PDA lives at `[b"season", season_id_le]` and stores the `seed_schedule` (default `[25, 19, 14, 10, 7]`) the `enter_contest` instruction reads to award seeds (see `docs/SOLANA.md`).

#### 2c. Per-contest Contest PDA init — **fires every time** in step 3

The contest PDA at `[b"contest", sha256(slug)]` is created by the `create_contest` instruction in step 3 below. There is no separate "init contract" click for this.

#### 2d. Per-user UserAccount PDA — fires lazily on first entry

`Solana::Vault#ensure_user_account` (`app/services/solana/vault.rb:690-700`) is called inline by every entry path (step 4 — `app/controllers/contests_controller.rb:728`). It checks the PDA size and either no-ops (`:ok`), creates the PDA via `create_user_account` (`app/services/solana/vault.rb:701-735`), or raises on schema drift (`:needs_migration`). For most admins this is a no-op because the after-commit hook on `User` enqueues `CreateOnchainUserAccountJob` at signup (`after_commit :enqueue_onchain_account_setup` — `app/models/user.rb:645-646`; job at `app/jobs/create_onchain_user_account_job.rb`; see `docs/AUTH.md`).

### 3. Admin creates a contest

Phantom-driven, three-step. The DB row is only created **after** the on-chain TX confirms — no orphans possible.

1. **`GET /contests/new`** — `app/controllers/contests_controller.rb:33-53`. Form lives at `app/views/contests/new.html.erb` — slate select (`:81-86`), `contest_type` (`:123-125`), **Starts At** (`:150-153`), `contest_image` (`:252`). `contest_type` is one of `Contest.selectable_formats` (`app/models/contest.rb:218-220`; respects the `ENABLE_TEST_SCAFFOLDING` flag via `AppFlags.test_scaffolding?`). The visible field is **Starts At** and defaults to the selected slate's first game kickoff (`default_start_for_slate` — `app/controllers/contests_controller.rb:2104-2106`); `Contest#starts_in_at` (`app/models/contest.rb:569`) is what the countdown and on-chain lock timestamp use. `entry_fee_cents` + `max_entries` are server-side derived from `format_config` (`app/models/contest.rb:229-231`) in `build_unpersisted_contest_from_params` (`app/controllers/contests_controller.rb:1673-1687`).
   - **Slate span (slates-sport-year):** the operator may extend a single slate into a **multi-week span** via a `week_span` field. `resolve_span_slate` (`app/controllers/contests_controller.rb:1698-1717`) resolves "N weeks from this anchor" into the ONE span slate the contest is played on, building it via `Nfl::BuildSpanSlate` if needed. The span is scoped to the anchor slate's season using the **`slates.year` column** (read through `Slate#season_year`, which falls back to the name only when the column is null — `app/controllers/contests_controller.rb:1710`) so a span never crosses seasons, and slate classification reads the **`slates.sport` column** via `Slate#sport` (surfaced by `sport_for_slate` — `app/controllers/contests_controller.rb:2116-2118`). Selectable slates come from `contest_slate_options` (`app/controllers/contests_controller.rb:2098-2102`). A span of 1 leaves the plain `slate_id` select untouched.
2. **Submit → `POST /contests`** — `ContestsController#create` (`app/controllers/contests_controller.rb:144-197`):
   - Refuses non-Phantom callers (`app/controllers/contests_controller.rb:145`).
   - `onchain_create_precheck` (`app/controllers/contests_controller.rb:1763-1795`) — model validation, slug uniqueness in DB (`:1778`), on-chain Contest PDA must not exist (`:1781-1788`), season readiness, then `insufficient_usdc_error` (`app/controllers/contests_controller.rb:1837-1880`) verifies the creator's ATA balance covers `guaranteed_prize_cents`.
   - `Solana::Vault#build_create_contest` (`app/services/solana/vault.rb:837-879`) builds a partially-signed `create_contest` TX — admin signs as payer, creator (admin's Phantom) signs the USDC transfer. Account layout is assembled in `create_contest_instruction` (`app/services/solana/vault.rb:880-926`): payer, creator, vault_state, contest (init), USDC mint, creator_ata, vault_usdc, token program, system program.
   - Server returns `{ serialized_tx, contest_pda, slug, params_token }`. The `params_token` is a `Rails.application.message_verifier` blob with a 10-minute TTL (`ONCHAIN_CREATE_TOKEN_TTL` — `app/controllers/contests_controller.rb:141-142`; signed in `sign_onchain_create_payload` — `app/controllers/contests_controller.rb:1882-1899`) so the server can trust the re-posted form fields in step 3d without re-validating them.
3. **Refresh blockhash + Phantom cosign + broadcast** — right before signing, the client calls `POST /contests/rebuild_create_tx` (`ContestsController#rebuild_create_tx` — `app/controllers/contests_controller.rb:199-226`) to re-issue the unsigned TX over a fresh blockhash. Then `app/views/contests/new.html.erb:451-470` deserializes via `solanaWeb3.Transaction.from`, `provider.signTransaction`, `connection.sendRawTransaction`, then `connection.confirmTransaction(txSig, 'confirmed')`.
4. **`POST /contests/finalize`** — `ContestsController#finalize` (`app/controllers/contests_controller.rb:228-273`). Collection route (no `:id`) defined at `config/routes.rb:245`.
   - `verify_onchain_create_payload` (`app/controllers/contests_controller.rb:1902-1906`) decodes the `params_token`.
   - Re-derives `contest_pda` from `Solana::Vault#contest_pda(slug)` (`app/services/solana/vault.rb:143`) and demands `params[:contest_pda]` matches (`app/controllers/contests_controller.rb:232-233`).
   - `verify_solana_transaction!` (helper at `app/controllers/contests_controller.rb:1943-1969`; called at `:252`) → `Solana::TxVerifier.verify!` (OPSEC-010) — asserts the on-chain TX is the `create_contest` instruction signed by `creator_pubkey` writing to the derived PDA.
   - `build_finalized_contest` (`app/controllers/contests_controller.rb:1737-1758`) constructs the DB row with `skip_onchain_callback = true` (so the legacy `Contest#create_onchain!` `after_create` hook doesn't fire and double-spend — `app/models/contest.rb:69-70`, set at `app/controllers/contests_controller.rb:1757`). `before_create` binds `season_id` to `SeasonConfig.current_season_id` (`app/models/contest.rb:76`).
   - Attaches `contest_image` if present, then `contest.save!` returns `{ success: true, redirect: contest_path(contest), slug: }` (`app/controllers/contests_controller.rb:263`).

> **Fallback path — server-funded.** `Contest#create_onchain!` (`app/models/contest.rb:244-268`) wired via `after_create :create_onchain_with_rollback!` (`app/models/contest.rb:70`, method at `:276-283`) calls `Solana::Vault#create_contest_server_funded` (`app/services/solana/vault.rb:927-996`). Admin signs as both payer and creator, with prize-pool USDC funded from the configured server/admin wallet. Used for Rails console / scripts; auto-skipped in tests (`Rails.env.test?` in `skip_onchain_callback_active?` — `app/models/contest.rb:269-271`). The UI does not use this path.

### 4. Admin enters their own contest

Admins follow the **same** path as any other Phantom-authenticated user — there is no admin-only shortcut. The `comped: true` escape hatch (`app/models/entry.rb:123-190`) is **only** used by `Contest#fill!` (`app/models/contest.rb:374-414`) for bot-seeded test entries, not by a real admin entering through the UI.

Two-stage hold-to-confirm followed by the Phantom direct-entry signing flow:

1. **Toggle 6 selections** on the matchup board — `POST /contests/:id/toggle_selection` per click (`app/controllers/contests_controller.rb:1016-1039`). Each call `find_or_create_by!` the cart entry and toggles a `Selection` row. World Cup Survivor contests use the `pick` action instead (`app/controllers/contests_controller.rb:1040-1069`), not `toggle_selection`.
2. **Hold-to-confirm** triggers the JS in `app/views/contests/_turf_totals_board.html.erb:1262` (`async confirmEntry()`):
   - Branches on `sess.isWeb3 && this.contestOnchain` (`app/views/contests/_turf_totals_board.html.erb:1323`). Admin = web3 = always takes the on-chain branch.
3. **`POST /contests/:id/prepare_entry`** — `ContestsController#prepare_entry` (`app/controllers/contests_controller.rb:660-777`):
   - Requires `onchain_session?` (`app/controllers/contests_controller.rb:683`) — admin's Phantom-auth session has it set in step 1.
   - Validates exactly `picks_required` (= 6 for Turf Totals — `Contest#picks_required` at `app/models/contest.rb:156-160`, backed by `TURF_TOTALS_DEFAULT_PICKS_REQUIRED = 6` at `:24`) selections (`app/controllers/contests_controller.rb:711`) and that none of the underlying games are `locked?` (`app/controllers/contests_controller.rb:713`).
   - Assigns `entry.entry_number` by **probing the chain for a free slot** via `Entry#assign_onchain_entry_number!` (`app/models/entry.rb:274-290`, called at `app/controllers/contests_controller.rb:723`) — it reads existing DB entry numbers, then asks `Solana::Vault#next_free_entry_index` for the first on-chain-free slot.
   - `Solana::Vault#ensure_user_account(current_user.web3_solana_address, username:)` (`app/controllers/contests_controller.rb:728`) — see 2d above.
   - `Solana::Vault#build_enter_contest(wallet, slug, entry_num, currency_idx:, season_id:)` (`app/services/solana/vault.rb:1262`, called at `app/controllers/contests_controller.rb:738`) builds the unified `enter_contest` transaction. Phantom-first flow leaves both admin and user signatures empty, then `confirm_onchain_entry` validates the user-signed wire before the server cosigns and broadcasts.
   - Persists a `PendingTransaction` with `tx_type: "enter_contest"`, `status: "pending"`, polymorphic `target: entry` (`app/controllers/contests_controller.rb:752`), so a mid-flight refresh leaves a recoverable trail.
   - Returns `{ serialized_tx, entry_id, entry_pda, ptx_slug }` (`app/controllers/contests_controller.rb:761-767`).
4. **Phantom signs, server broadcasts** — the browser signs the prepared wire transaction and posts it to `confirm_onchain_entry`; the server validates the signed wire, cosigns with the admin key, simulates, broadcasts, stamps the `PendingTransaction`, and verifies the resulting signature.
5. **`POST /contests/:id/confirm_onchain_entry`** — `ContestsController#confirm_onchain_entry` (`app/controllers/contests_controller.rb:899-994`):
   - Delegates to `verify_and_confirm_onchain_entry!` (`app/controllers/contests_controller.rb:1971-1985`, called at `:964` with the client-supplied `params[:entry_pda]`), which re-derives `entry_pda` via `Solana::Vault#entry_pda(slug, wallet, entry_number)` (`app/controllers/contests_controller.rb:1972-1973`) and rejects a mismatched client-supplied PDA (`:1975`).
   - `verify_solana_transaction!` (`app/controllers/contests_controller.rb:1977-1981`) asserts the TX is `enter_contest` signed by the user's wallet, cosigned by the admin server key, and writing to the derived entry PDA (OPSEC-010).
   - `Entry#confirm_onchain!` (`app/models/entry.rb:234-272`) promotes the entry to `active`, stamps `onchain_tx_signature` + `onchain_entry_id`. The `comped:` flag is NOT passed — the on-chain path is user-initiated only and the on-chain TX itself is the payment proof (`app/models/entry.rb:239`).
   - Marks the PT `confirmed`, returns `{ success: true, redirect, tx_signature, seeds_earned, seeds_total, seeds_level }`.

## Data touched

- **DB:**
  - `users` (read — `from_solana_wallet`; insert if first login for this pubkey)
  - `season_configs` (read — `SeasonConfig.current_season_id`)
  - `slates` (read — the selected slate; on a span, its consecutive weekly siblings scoped by the `year`/`sport` columns via `resolve_span_slate` → `Nfl::BuildSpanSlate`)
  - `slate_matchups` (read — the pickable matchups behind the selections)
  - `contests` (insert — finalize step; sets `onchain_contest_id`, `onchain_tx_signature`)
  - `entries` (insert via `toggle_selection`; update to `active` via `confirm_onchain!`)
  - `selections` (insert per matchup toggle)
  - `pending_transactions` (insert in `prepare_entry`; update `tx_signature` + `status` through the lifecycle)
  - `transaction_logs` (insert of an audit row at `confirm!` time when entry fee > 0 — `TransactionLog.record!` at `app/models/entry.rb:185-190`; this fires on the off-chain `confirm!` path, not the on-chain admin path in step 4)
  - `outbound_requests` (insert per Solana RPC call via `Solana::ClientLogger`)
- **On-chain (turf-vault):**
  - `VaultState` PDA at `[b"vault"]` (read; **init** if 2a fires)
  - `Season` PDA at `[b"season", season_id_le]` (read; **init** if 2b fires)
  - `UserAccount` PDA at `[b"user", wallet]` (read; **init** if 2d fires — `ensure_user_account`)
  - `Contest` PDA at `[b"contest", sha256(slug)]` (**init** via `create_contest` IX in step 3)
  - `ContestEntry` PDA at `[b"entry", contest_pda, wallet, entry_num_le]` (**init** via `enter_contest` IX in step 4)
  - SPL token transfers: creator ATA → per-contest prize-pool ATA for the prize pool (step 3); user ATA → per-currency operator-revenue ATA for the entry fee (step 4)
- **External:** Solana RPC (every `build_*` re-derives PDAs; server-signed paths use `client.send_and_confirm`; Phantom entry signs in-browser and broadcasts server-side after admin cosign).

## Failure modes

- **Wrong wallet connected** — `app/views/contests/new.html.erb:415` (creation) and `app/views/contests/_turf_totals_board.html.erb:1345` (entry) throw client-side before signing. User-visible: error "Wrong wallet connected. Switch to <pubkey>…".
- **Insufficient USDC for prize pool** — `onchain_create_precheck` calls `insufficient_usdc_error` (`app/controllers/contests_controller.rb:1794`); client modal offers a "Mint $500 Test USDC" recovery button (`app/views/contests/new.html.erb:353`) hitting `POST /faucet` (`app/views/contests/new.html.erb:360`). Production-disabled per OPSEC-020 (`app/controllers/admin_controller.rb:353`).
- **On-chain Contest PDA already exists** — `onchain_create_precheck` (`app/controllers/contests_controller.rb:1781-1788`). Common after a finalize that confirmed on-chain but failed at `verify_solana_transaction!` or `save!`. Admin must pick a different name (slug-derived) or operate manually on the stranded PDA.
- **No active season** — `app/controllers/contests_controller.rb:558-559` raises in `#enter`. User-visible alert: "No active season configured. Set one at /admin/seasons before users can enter on-chain contests." → admin loops back to 2b.
- **Sign-then-refresh during entry** — `PendingTransaction` left as `pending` or `submitted`. The board JS polls `POST /contests/:id/recover_pending_entry` (`app/controllers/contests_controller.rb:803-897`) which either promotes the entry (`status == confirmed`/`finalized`), keeps polling (`processing`), or fails-and-releases (`failed`).
- **IDL hash drift after a turf-vault upgrade** — `Solana::Config.verify_idl!` refuses to boot/precompile in production (`docs/SOLANA.md:3`). Borsh decoding would silently corrupt every account read otherwise. Operator must re-pin `EXPECTED_IDL_HASH` from the freshly **built** IDL (NOT `anchor idl fetch`) before pushing (`docs/SOLANA.md:101-114`). See `feedback_post_deploy_idl_pin` memory.
- **Session token mismatch** — `ApplicationController#verify_session_token` (`app/controllers/application_controller.rb:248-270`) force-logs-out a stale session (OPSEC-045). Admin re-runs step 1.
- **Tx fails `Solana::TxVerifier`** — controller rescues `VerificationError` and surfaces the message via JSON `{ error }`; the finalize / confirm endpoint returns 422 without creating the DB row. The on-chain side may already be committed — operator inspects via `/admin/outbound_requests` + Solana explorer.

## Related workflows

- [[web3-landing-to-entry]] — same Phantom auth + Phantom direct-entry signing path, just from a non-admin user landing on `/l/:slug` instead of `/contests/new`. Steps 1 and 4 above are shared.
- [[email-signup-token-to-chat]] — managed-wallet alternative entry path: `ContestsController#enter` falls through to a web2-funded branch that consumes an `EntryTokenAccount` PDA instead of charging USDC, via `resolve_web2_entry_funding!` (`app/controllers/contests_controller.rb:1409-1495`, which calls `Solana::Vault#enter_contest_with_token` at `:1429`). Admin never hits this branch.
- [[referral-google-tokens-to-chat]] — Google OAuth signup path; lands the user in the same `enter` action with a managed wallet, taking the token-consume branch.
- [[slate-build]] — the predecessor for NFL contests. A contest is opened on a Slate, and `ContestsController#create` builds (or reuses) the span slate via `Nfl::BuildSpanSlate.call` (`app/controllers/contests_controller.rb:1708`). That slate's frozen `turf_score` is what settlement multiplies by, so it must not be rebuilt after picks land.
