# Local Stack

Use this when an agent or background session needs to run Turf Monster locally and hand back an inspectable URL.

## Primary Stack

Primary local URL:

```text
http://localhost:3100
```

Start or adopt the normal local stack:

```bash
bin/tm up
```

`bin/tm` manages:

- Rails web on `3100`.
- Sidekiq on `default` and `mailers`.
- Redis and Postgres preflights.
- One-shot Tailwind build.
- Readiness polling before reporting the URL.

Stripe checkout is retired by default. The local Stripe listener is dormant
unless a task explicitly revives the legacy card checkout rail:

```bash
PAYMENT_PROVIDER=stripe bin/tm up --stripe
```

That listener forwards to `localhost:3100/webhooks/stripe` and verifies the
printed signing secret against `.env`.

Useful commands:

```bash
bin/tm status
bin/tm logs web
bin/tm logs sidekiq
bin/tm restart
bin/tm down
```

Use `bin/tm logs stripe` only after starting the stack with `--stripe`.

Use `bin/tm restart` after changing `.env`, gems, migrations, or anything Sidekiq reads at boot.

## Human Interactive Stack

`bin/dev` is for an interactive terminal where combined logs are useful. It does not start the Stripe listener and can self-terminate in background/no-TTY agent sessions because the Tailwind watcher exits.

Agents should prefer `bin/tm up`.

## Desk Stacks And Review Links

A desk stack is a worktree stack: `bin/agent-worktree up turf-monster <task-slug>`
on an allocated port in the `3100-3199` band. **A desk owns its own database.**
`.env.agent-stack` sets `DATABASE_URL` to
`turf_monster_development_<task_slug>`, and every desk gets a different one.

### Hand back a review link with `bin/review-link`

When work waits on Mr. McRitchie's review, hand him one click that signs him in
and lands him on the page:

```bash
bin/review-link "/admin/style#host-modals"
# http://localhost:3122/_studio/local_review?return_to=/admin/style%23host-modals
```

It reads the port from `.env.agent-stack`, proves the link round-trips against
the running stack, and prints nothing if it does not. Put the result on a
`Magic Link:` label above `Local Demo:`.

That URL is reusable — every click mints its own fresh single-use token — so
checking it costs the operator nothing.

### Do not mint tokens in a console

This is the trap, and it is quiet:

```bash
bin/rails runner 'puts Studio::Link.create_magic_link(email: "…").token'   # WRONG on a desk
```

**Nothing in `config/` or `bin/` loads `.env.agent-stack`.** A bare `bin/rails`
in a worktree therefore falls through `config/database.yml` to the shared
`turf_monster_development` and mints the row *there*. The desk server reads its
own database, `Studio::LinksController#show` finds no such token, and the
operator is bounced to `/signin` — holding a link that is alive, unexpired and
unconsumed in a database nobody is serving. Nothing in the message says
"database"; it reads as an expired link.

Measured 2026-09-09: 26 review links were minted into the shared development
database over three days, and exactly one was ever consumed.

Two things make it hard to catch by hand:

- A hand-minted `/l/<token>` is **single-use**. Opening it to check it burns it,
  so the second look fails and looks like the bug.
- The failure is indistinguishable from an expired link at the door.

If you must mint by hand, source the desk env first and verify by `curl`, never
by eye:

```bash
set -a; source .env.agent-stack; set +a
bin/rails runner 'l = Studio::Link.create_magic_link(email: "alex@mcritchie.studio",
  return_to: "/admin/style", ttl: 12.hours); puts "http://localhost:#{ENV.fetch("PORT")}/l/#{l.token}"'
```

`ENV.fetch("PORT")` is deliberate: without the `source` line it raises instead
of printing a URL that cannot work.

### Which database am I on?

```bash
bin/rails runner 'puts ActiveRecord::Base.connection_db_config.database'
```

On a desk that must print `turf_monster_development_<task_slug>`. If it prints
`turf_monster_development`, the shell has not loaded `.env.agent-stack` and any
row you write lands where the desk server will not look.

## Testing Notes

Rails unit/integration tests run against the test database and use `Rails.cache` as `:null_store` by default. Tests that need cache reads must inject or stub a real store, usually `ActiveSupport::Cache::MemoryStore`, for the branch under test.

Playwright specs run against a live dev server from `playwright.config.js`. Seed with `bin/rails runner e2e/seed.rb` against the dev database unless a spec explicitly provisions its own isolated server/database pair.

### Two e2e lanes

The Playwright suite is split into two lanes by a `@smoke` tag embedded in the
test title (same title-tag convention as `@devnet`):

- **General / smoke lane** — the fast, core happy-path specs: auth (`auth_modal`,
  `magic_link`), account update (`account_avatar`), and navigation page-loads
  (`navigation`). Run it **often** while developing:
  - `npm run test:smoke` (= `npx playwright test --grep @smoke`)
  - `npm run test:smoke:parallel` (= `bin/e2e-parallel -- --grep @smoke`)
- **Comprehensive lane** — everything else (on-chain, quests, referrals, geo,
  survivor, the login-driven gear-sidebar back-nav loop, etc.). Run it at **PR
  review and after a release is cut**:
  - `npm run test:comprehensive` (= `npx playwright test --grep-invert @smoke`)
  - `npm test` / `npm run test:parallel` still run the FULL suite (both lanes).

To add a spec to the smoke lane, append ` @smoke` to its `test(...)` title.

`@devnet` specs hit the deployed devnet program and run in their own Playwright
project (nightly CI); they are excluded from the default `chromium` project.

### Running the parallel launcher (`bin/e2e-parallel`)

`bin/e2e-parallel [N]` runs the suite across N isolated test-env stacks. Env knobs:

- `E2E_BASE_PORT` — first stack port (default `3101`).
- `E2E_UP_TIMEOUT` — seconds to wait for each stack's `/up` (default `180`; raise
  on a loaded machine).
- `E2E_KILL_STRAY=1` — in the port preflight, kill any process already listening
  on a target port instead of aborting (default: report + abort).
- `E2E_PARALLEL_SEED=1` — restore the fully-parallel prepare+seed+boot. By
  default the prepare+seed step is **serialized** (it can hit Solana RPC; N
  concurrent seeds contend and can blow the `/up` probe), and only the server
  boot is parallelized.

## Callback Rule

Keep callback-heavy flows on the primary stack unless the external provider is configured for a worktree port.

Primary `3100` is used by:

- Legacy Stripe webhook forwarding only when started with `bin/tm up --stripe`.
- Google OAuth redirects.
- MoonPay/CDP callbacks.
- Webhooks.
- Emailed magic links.

Worktree stacks should use `3101+` and separate Redis DBs.

Prefer McRitchie Studio's central launcher for named parallel stacks:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-worktree new turf-monster task-slug
bin/agent-worktree up turf-monster task-slug
```

This creates the worktree under `turf-monster/.worktrees/`, assigns the port, database, Redis DB, and session cookie key, then prints the review URL.

The launcher also prints a local email inbox:

```text
http://localhost:<port>/_studio/local_emails
```

Worktree stacks default to `LOCAL_EMAIL_CAPTURE=1`, so magic links and other
transactional emails are recorded there instead of sent through Resend/SES.
Agents should hand back this URL for auth proof flows. Only disable capture for
tasks that explicitly test provider delivery.

## Required Local Secrets

At minimum, `.env` needs:

- `RAILS_MASTER_KEY`
- `SECRET_KEY_BASE`
- `GOOGLE_CLIENT_ID`
- `GOOGLE_CLIENT_SECRET`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `SOLANA_ADMIN_KEY`
- `SOLANA_RPC_URL`
- `MANAGED_WALLET_ENCRYPTION_KEY`

`SOLANA_PUBLIC_RPC_URL` is optional and normally unset locally — it is the
BROWSER-facing endpoint, and locally `SOLANA_RPC_URL` carries no credential, so
the browser is handed the same URL. See "RPC endpoints — server vs browser" in
`docs/SOLANA.md`.

Use McRitchie Studio's agent credential docs for current 1Password item names. Do not print secret values in terminal output or handoff notes.
