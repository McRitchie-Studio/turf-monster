# Turf Monster

Sports pick'em game for the FIFA World Cup 2026. Players select 6 team matchups with multipliers per entry, scored by actual goals. Features Solana blockchain integration for contest escrow and prize distribution.

**Live**: https://turfmonster.media

Legacy alias: https://app.turfmonster.media

Turf Monster is a **satellite product app** in the [McRitchie Studio](https://github.com/amcritchie/mcritchie-studio) ecosystem. McRitchie Studio owns the shared recovery scripts and agent-neutral docs.

> **Part of the McRitchie ecosystem** — see [`ECOSYSTEM.md`](https://github.com/amcritchie/mcritchie-studio/blob/main/docs/ECOSYSTEM.md) for the 5-repo map; [`house-burn-down.md`](https://github.com/amcritchie/mcritchie-studio/blob/main/docs/agents/system/house-burn-down.md) for fresh-Mac recovery.

---

## Standing up a fresh Mac? Start at the flagship.

The canonical way to install Turf Monster + all 4 sibling repos + the toolchain is from McRitchie Studio's `bin/ecosystem-build` script. It clones this repo, restores `.env` from Heroku, pulls `SOLANA_ADMIN_KEY` from 1Password, runs `db:create db:migrate db:seed`, and boots the server on port 3100 — all idempotent.

```bash
git clone https://github.com/amcritchie/mcritchie-studio.git ~/projects/mcritchie-studio
cd ~/projects/mcritchie-studio
bin/ecosystem-build   # 1st pass: installs toolchain, bails for 1Password token
bin/setup-1pass-token # paste token from clipboard
bin/ecosystem-build   # 2nd pass: completes everything incl. Turf Monster
```

See [mcritchie-studio/docs/agents/system/house-burn-down.md](https://github.com/amcritchie/mcritchie-studio/blob/main/docs/agents/system/house-burn-down.md) for the full protocol.

---

## Single-app dev (when you already have the toolchain)

If your machine already has Ruby 3.3.11 (via `brew install ruby@3.3`), Postgres 14, Redis, Node 22, and an `.env` in place:

```bash
git clone https://github.com/amcritchie/turf-monster.git
cd turf-monster
bundle install
bin/rails db:create db:migrate db:seed
bin/tm up
```

`bin/tm up` starts or adopts the agent-friendly detached stack: web on port 3100, Sidekiq, Tailwind build, and Stripe listener when available. Open http://localhost:3100 and sign in with a magic link. See [`docs/LOCAL_STACK.md`](docs/LOCAL_STACK.md).

`bin/dev` remains available for a human interactive terminal with combined logs, but it does not start the Stripe listener and is not reliable in background/no-TTY agent sessions.

Seeds create 5 users, 48 World Cup teams plus 31 knockout-slot placeholders, 32 NFL teams, 38 NFL schedule venues, 104 World Cup matches (72 group-stage, 32 knockout), 256 NFL regular season games across 17 slates, and 85 players.

**Required `.env` keys**: `RAILS_MASTER_KEY` (not optional — seed encrypts managed wallets via `secret_key_base`), `GOOGLE_CLIENT_ID`/`SECRET`, `AWS_ACCESS_KEY_ID`/`SECRET`, `SOLANA_ADMIN_KEY`, `SOLANA_RPC_URL` (server-side; `SOLANA_PUBLIC_RPC_URL` is the optional browser-facing sibling), `MANAGED_WALLET_ENCRYPTION_KEY`, and mail transport credentials for local email delivery. Current 1Password item names live in McRitchie Studio's credential docs.

## Prerequisites (single-app path)

- Ruby **3.3.11** (use `brew install ruby@3.3`; matches `.ruby-version` and `Gemfile`)
- PostgreSQL 14+
- Redis (Sidekiq queue)
- Node.js **22.x** (keeps local dev, CI, and Heroku aligned; turf-vault needs at least Node 20.18.0)
- Bundler 2.4+

## Test

```bash
# Rails tests
bin/rails test

# Playwright E2E (chromium project — skip @devnet which needs a funded wallet)
npm test
npm run test:headed             # with visible browser
```

## Key Features

- **Matchup grid** with team selection, multipliers, and animated hold-to-confirm button
- **Contest lifecycle**: pending, open, settled, with locked/concluded derived from timestamps and admin controls for fill, jump, grade, and reset
- **Multiple entries** per user per contest with different selection combos
- **Scoring**: team goals x multiplier per selection, entries ranked, payouts distributed
- **Solana integration**: on-chain contest escrow via [TurfVault](https://github.com/amcritchie/turf-vault) Anchor program
- **Phantom wallet** connect, self-custody USDC/USDT entry, and on-chain payouts
- **Dark/light theme** toggle with green primary palette

## Release flow

Turf Monster integrates through the McRitchie Studio DevOps cycle on a
three-rung branch ladder — **`accepted` → `release` → `main`**:

- **Feature PRs target `accepted`.** Cut `feat/<slug>` from `accepted` and open
  the PR into `accepted` — never against `release` or `main`. Review merges it to
  `accepted` and moves the task to `reviewed`.
- **The studio sweep promotes `accepted` → `release`.** `bin/release prepare`
  opens one batch PR per repo and merges it, so the `release` tip earns its own
  CI verdict.
- **Ship fast-forwards `release` → `main` and deploys production** via
  `bin/deploy` (see [Deploy](#deploy) below).

`main` holds shipped integration; it is not a merge target. The full cycle lives
in the hub —
[`devops-cycle-design.md`](https://github.com/amcritchie/mcritchie-studio/blob/main/docs/agents/system/devops-cycle-design.md).

## Deploy

```bash
bin/deploy   # single mainnet target → turf-monster-mainnet (real funds, confirms)
```

Migrations run in Heroku's release phase (Procfile `release:`), not the deploy
script. `MAINNET_LAUNCH.md` is historical first-launch context; current deploys use `bin/deploy`. Platform: Heroku (heroku-24 stack) with buildpacks ordered `heroku/nodejs` then `heroku/ruby` so `package.json` pins Node 22 for asset builds. Required env vars include `RAILS_MASTER_KEY`, `RAILS_SERVE_STATIC_FILES=true`, `SOLANA_ADMIN_KEY`, `SOLANA_RPC_URL`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, and the active mail transport settings. Any app whose `SOLANA_RPC_URL` carries a provider api-key should also set `SOLANA_PUBLIC_RPC_URL` — see "RPC endpoints — server vs browser" in `docs/SOLANA.md`.

After every deploy, run the smoke checklist in [`RUNBOOK.md`](RUNBOOK.md):
release output, `/up`, the live contest URL, payment-provider gates, and a real
magic-link email job. Production email currently uses Resend fallback from
`McRitchie Studio <team@mcritchie.studio>` until SES production access is
approved.

## Solana Integration

The app connects to the TurfVault Anchor program for contest escrow. Users with Phantom wallets can enter contests on-chain and receive payouts. The `SOLANA_ADMIN_KEY` env var holds the admin bot's base58 private key. Live deployment identity lives in `turf-vault/docs/CURRENT_DEPLOYMENT.md`; app integration details live in `docs/SOLANA.md`.

## Architecture

- Rails 8.1 with ERB views, Tailwind CSS, Alpine.js
- Shared [Studio engine](https://github.com/amcritchie/studio-engine) for auth, error handling, and theme system
- [SolanaStudio](https://github.com/amcritchie/solana-studio) gem for Solana RPC and transaction building
- Slug-based foreign keys for teams, games, players, and home arenas
- Team records carry sport/league/division metadata, rivalry/social fields, and optional `home_arena_slug` links to `Arena`
- All monetary values stored in cents, displayed in dollars

## Development Notes

See McRitchie Studio's generated `AGENTS.md` entrypoint for cross-repo agent
guidance. Treat the docs below as active source of truth.

Topic-specific documentation lives in `docs/`:

| File | Topic |
|------|-------|
| `docs/AUTH.md` | Authentication, account management, SSO |
| `docs/LOCAL_STACK.md` | Agent-friendly local stack, ports, Sidekiq, Stripe listener |
| `docs/SOLANA.md` | Solana integration, wallet types, on-chain flows |
| `docs/FORMULAS.md` | Scoring formulas, slate system, Chart.js patterns |
| `docs/SECURITY_REVIEW.md` | Current security/readiness review checklist |
| `docs/TEST_COVERAGE_STATUS.md` | Current test-coverage orientation and remaining gaps |
| `docs/UI_PATTERNS.md` | Branding, theme, matchup grid, animations |
| `docs/world_cup_2026.md` | World Cup format, groups, matchday structure |
