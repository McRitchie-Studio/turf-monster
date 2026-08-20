# Runbook -- Turf Monster

Troubleshooting guide for autonomous agents. Format: problem, diagnosis, fix.

## Heroku Deploy Failures

**Post-deploy smoke checklist**
- Diagnosis: A deploy is not done until the new release, payment flags, public
  URLs, and email delivery path are proven.
- Fix:
  1. Confirm the current release: `heroku releases --app turf-monster-mainnet`.
  2. Confirm release output has no boot failure:
     `heroku releases:output <release> --app turf-monster-mainnet`.
  3. Check public URLs:
     `https://turfmonster.media/up`,
     `https://turfmonster.media/contests/world-cup-week-3-contest`, and
     legacy alias `https://app.turfmonster.media/up`.
  4. Confirm payment gates in a production runner: `PAYMENT_PROVIDER=none`,
     `Payments.stripe?=false`, `Payments.paypal_checkout?=false`,
     `AppFlags.cdp_ramp?=true`, and `AppFlags.web2_usdc_entry?=true` unless
     the operator intentionally changed them.
  5. Trigger a real magic-link request through `/signin`; then confirm the
     matching `EmailDeliveryJob` finishes in worker logs. A JSON success
     response from `/magic_link` proves only that the send intent was accepted.

**Build error: Tailwind CSS compilation**
- Diagnosis: `assets:precompile` fails. Usually a new CSS class that references undefined variables or syntax error in `app/assets/tailwind/application.css`.
- Fix: `bin/rails tailwindcss:build` locally to reproduce. Fix the CSS. Redeploy.

**Build warning: Heroku selected an unpinned Node**
- Diagnosis: Heroku logs `Installing a default version ... of Node.js`.
- Fix: Keep the root `package.json` `engines.node` pinned to the repo-supported
  version (`22.x`). Production should have buildpacks ordered `heroku/nodejs`
  then `heroku/ruby`; if the warning returns, check
  `heroku buildpacks --app turf-monster-mainnet` before deploying again.

**Sentry warning: Dyno Metadata disabled**
- Diagnosis: Release output says Sentry cannot detect releases on Heroku.
- Fix: Heroku runtime dyno metadata should be enabled for
  `turf-monster-mainnet`. If the warning returns, run
  `heroku labs --app turf-monster-mainnet` and confirm
  `runtime-dyno-metadata` is on, then restart or redeploy so dynos pick up the
  metadata env.

**Missing env vars on Heroku**
- Diagnosis: App crashes on boot. Check `heroku logs --tail --app turf-monster-mainnet`.
- Fix: Compare `heroku config --app turf-monster-mainnet` against
  `.env.example`, then use the owning docs for provider-specific values:
  `docs/email-delivery.md` for mail, `docs/SOLANA.md` for Solana, and
  `docs/CDP_RAMP_INTEGRATION.md` for Coinbase CDP. Boot fails closed without
  `MANAGED_WALLET_ENCRYPTION_KEY` (OPSEC-015), `SOLANA_PROGRAM_ID`
  (OPSEC-012), or `EXPECTED_IDL_HASH` (OPSEC-014). Set missing values with
  `heroku config:set KEY=value --app turf-monster-mainnet`.

**Magic-link request succeeds but email never arrives**
- Diagnosis: `/magic_link` returns `{"success":true}` but Sidekiq logs show a
  provider error, often `Resend::Error: The <domain> domain is not verified`.
- Fix: Keep `RESEND_MAILER_FROM="McRitchie Studio <team@mcritchie.studio>"`
  while SES is sandboxed. Confirm `mcritchie.studio` is verified in the Resend
  account behind `RESEND_API_KEY`; the required public DNS records are:
  `TXT resend._domainkey.mcritchie.studio`, `MX send.mcritchie.studio`, and
  `TXT send.mcritchie.studio`. Trigger Resend verification and wait for status
  `verified`, then retry `EmailDelivery.resend_unsent!` or request a fresh
  magic link.

**Migration fails**
- Diagnosis: `heroku run bin/rails db:migrate --app turf-monster-mainnet` errors. Check exact SQL error in logs.
- Fix: Connect via `heroku pg:psql --app turf-monster-mainnet` to inspect state. If partially applied, check `schema_migrations` table.

## Solana RPC Errors

**Rate limit (HTTP 429)**
- Diagnosis: `Solana::Client` retries automatically but exhausts retries. Logs show `429 Too Many Requests`.
- Fix: Check `SOLANA_RPC_URL`. Public RPC rate-limits aggressively. Switch to a provider RPC (QuickNode, Helius). Set via `heroku config:set SOLANA_RPC_URL=<provider_url> --app turf-monster-mainnet`.

**Timeout on RPC calls**
- Diagnosis: `Net::OpenTimeout` or `Net::ReadTimeout`. RPC node is slow or down.
- Fix: Try a different RPC endpoint. Check Solana network status at status.solana.com. The gem defaults to devnet public RPC if `SOLANA_RPC_URL` is unset.

**Wrong network (mainnet vs devnet)**
- Diagnosis: Transactions fail with "account not found" or wrong program ID.
- Fix: Verify `SOLANA_NETWORK`, `SOLANA_RPC_URL`, `SOLANA_PROGRAM_ID`, and the committed IDL file agree. Devnet uses `EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ`; mainnet uses `DaFv83yokwTz8msP9CzJ13eazSGk15NuUTxjkfzJzxMM`. Live deployment identity is canonical in `/Users/alex/projects/turf-vault/docs/CURRENT_DEPLOYMENT.md`. Run `bin/rails solana:preflight` or `bin/rails solana:health` before changing production config.

## Phantom Wallet Connection Issues

**Wallet auth fails silently**
- Diagnosis: `toggle_selection` is a JSON fetch -- guests get no redirect, just a silent failure. Check browser console for 401 responses.
- Fix: User must be logged in. Wallet auth flow: `/auth/solana/nonce` (GET) then `/auth/solana/verify` (POST with signed nonce). Verify the nonce endpoint returns JSON. Check that `SolanaAuthController` exists and routes are drawn.

**Balance shows $0 despite onchain funds**
- Diagnosis: `display_balance` calls `fetch_user_usdc` which reads the user's Phantom wallet ATA balance. Returns 0 if ATA does not exist or RPC fails.
- Fix: Check the user has a `solana_address` and `wallet_type: "phantom"`. Verify their ATA exists: `bin/rails runner "puts Solana::Client.new.get_token_account_balance('<user_ata>')"`. If ATA missing, user needs to receive USDC first (use `/faucet`).

## Contest Lifecycle Bugs

**Double grade (contest already settled)**
- Diagnosis: `Contest#grade!` called on an already-settled contest. Current code raises before regrading settled contests.
- Fix: Confirm `contest.settled?` and review `entries` before changing data. If a legacy or console path double-graded, use `Contest#reset!` to clear derived scoring fields and re-grade once. Check `entries` for duplicate `payout_cents` values.

**Stuck contest status**
- Diagnosis: Contest not visible or admin buttons not appearing. Current statuses are `pending`, `open`, and `settled`; locked is derived from `starts_at`, not stored as a status.
- Fix: Admin buttons are gated by `current_user.admin?`. Verify the user has `role: "admin"`. Check contest status and timing in console: `contest = Contest.find_by(slug: "<slug>"); [contest.status, contest.starts_at, contest.locked?]`. Manually transition only when appropriate: `contest.update!(status: "open")`.

**Payout calculation errors**
- Diagnosis: Payouts don't add up or ties split wrong.
- Fix: `grade!` ranks entries by score DESC, ties get same rank, payouts for tied ranks are averaged across spanned positions. Check `Entry` records: `Contest.find_by(slug: "<slug>").entries.order(rank: :asc).pluck(:slug, :score, :rank, :payout_cents)`.

## Balance Issues

**On-chain USDC balance not showing**
- All balances are on-chain USDC.
- Use `/wallet` sync button or check: `bin/rails runner "vault = Solana::Vault.new; puts vault.fetch_wallet_balances(User.find_by(slug: '<slug>').solana_address)"`.
- If ATA doesn't exist: `bin/rails runner "vault = Solana::Vault.new; vault.ensure_ata('<address>', mint: Solana::Config::USDC_MINT)"`.

## Geo-Blocking Not Working

**GeoIP lookup returns nil**
- Diagnosis: `geocoder` gem cannot resolve the IP. Localhost (`127.0.0.1`) always returns nil.
- Fix: GeoIP only works with real public IPs. In development, test with `Geocoder.search("<real_ip>")`, or set `DEV_GEO_STATE` to stand somewhere real on loopback. Check `Studio::GeoSetting` at `/admin/geo` (the engine's manager since studio-engine 0.57). Blocked regions are stored as tokens — `US-WA`, not `WA`, because "CA" is California and Canada; the page still shows the bare code. Full guide: the gem's `docs/GEO.md`.

## Tailwind Classes Not Compiling

**New utility class doesn't render**
- Diagnosis: `tailwindcss-rails` only compiles classes found in app views at build time. A class like `bg-red-500` won't work if no other view uses it.
- Fix: Three options: (1) Use a class already present in other views. (2) Add the class to the safelist in `config/tailwind.config.js`. (3) Use inline `style="..."` for one-offs.

**`backdrop-blur`, `border-r-transparent` etc. missing**
- Diagnosis: Some Tailwind utilities aren't compiled by `tailwindcss-rails` if not referenced elsewhere.
- Fix: Use inline `style` instead. Example: `style="backdrop-filter: blur(8px)"` instead of `backdrop-blur`.

## Hold Button Not Working

**Button does nothing on click/hold**
- Diagnosis: Alpine.js guard expressions broken by ERB escaping. `<%= %>` inside `<script>` tags HTML-escapes `>` to `&gt;`, breaking JS silently.
- Fix: Use `<%== %>` (raw output) for any Ruby expressions inside `<script>` tags. Search for `<%=` inside `<script>` blocks and replace with `<%==`.

**Alpine.js Proxy infinite loop (Chart.js)**
- Diagnosis: Browser freezes or console shows stack overflow. Caused by storing a Chart.js instance as an Alpine reactive property.
- Fix: Never store Chart.js instances in Alpine `data()`. Use plain `var` globals outside Alpine scope (e.g. `var _fcChart = null;`).

## Theme Cache Stale

**Theme colors not updating**
- Diagnosis: `ThemeSetting` updated but page shows old colors. Cache key: `studio/theme/Turf Monster`.
- Fix: `bin/rails runner "Rails.cache.delete('studio/theme/Turf Monster')"`. Or hit "Regenerate Cache" at `/admin/theme`. TTL is 1 hour.

## Playwright E2E Test Failures

**Tests fail with wrong data**
- Diagnosis: E2E tests expect data from `e2e/seed.rb` (2 users, 1 contest, 6 matchups). If dev server is running, tests hit the dev database instead.
- Fix: Stop the dev server before running `npm test`. E2E config (`playwright.config.js`) starts its own server on port 3100. Alternatively, run `ruby e2e/seed.rb` against dev DB to align data.

**Stale seed data**
- Diagnosis: Seed is idempotent but if dev DB schema changed, seed may fail.
- Fix: `bin/rails db:migrate && ruby e2e/seed.rb`.

## Studio Engine Update Issues

**`bundle update studio-engine` fails**
- Diagnosis: Network or git auth issue.
- Fix: `git ls-remote https://github.com/amcritchie/studio-engine.git`. Clear cache: `rm -rf vendor/cache/studio-*`. Try `bundle update studio-engine --verbose`.

**Zeitwerk autoload conflict with SolanaStudio gem**
- Diagnosis: `Solana::Keypair` defined by the gem at boot. Zeitwerk won't autoload the app's reopening in `app/services/solana/keypair.rb`.
- Fix: The explicit require in `config/initializers/solana.rb` handles this. If the initializer is missing: create it with `require Rails.root.join("app/services/solana/keypair")`.

**Breaking engine change**
- Diagnosis: App crashes after `bundle update studio-engine`. New config option or renamed method.
- Fix: Check studio-engine commits: `cd /Users/alex/projects/studio-engine && git log --oneline -10`. Pin to a known-good tag if needed: `gem "studio-engine", git: "...", tag: "v0.X.Y"`.
