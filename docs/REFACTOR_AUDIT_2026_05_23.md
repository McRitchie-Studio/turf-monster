# Stage 2 — Refactor / Scalability Audit

> **ARCHIVE-ONLY AUDIT SNAPSHOT.** This report captured May 2026 launch-risk
> findings. Use current app docs, tests, and McRitchie Studio's June 2026
> ecosystem audits for active procedure.

**Date:** 2026-05-23
**Companion to:** [`SECURITY_AUDIT_2026_05_23.md`](SECURITY_AUDIT_2026_05_23.md)
**Scope:** models, controllers, DB/queries, jobs + ActionCable
**Stage 3 (test coverage) is queued next.**

---

## Executive summary

One new launch blocker surfaced during this audit. Everything else is architectural debt that's surviveable for launch but will hurt you between 500–10k DAU. I verified each high-severity claim against the source — items that came back as overstated or already-mitigated are noted in the reconciliation table below.

**Top-line counts** (after deduplication + spot-checks): 1 new launch blocker · 5 high-severity refactors · 9 medium · 7 low.

**The blocker:** `config/environments/production.rb:76` overrides the global `:sidekiq` queue adapter back to `:async`. That means `perform_later` calls (TokenPurchaseJob, StripeDepositJob, MoonpayDepositJob, mailers) run in the web dyno's thread pool, not on the Sidekiq worker. The worker dyno you're paying for is sitting idle except for the cron sweeper. Jobs are lost on dyno restart. This is a one-line fix and it has to ship before mainnet.

---

## Reconciliations (verified)

| Claim | Verdict | Evidence |
|---|---|---|
| `production queue_adapter = :async` (Critical) | **CONFIRMED** | `production.rb:76` literally `:async`; `application.rb:20` sets `:sidekiq` globally but production overrides. Procfile has `worker: bundle exec sidekiq` (dyno running but receiving nothing from `perform_later`). |
| Contest is 433 lines (Critical fat model) | **CONFIRMED** | `wc -l contest.rb` = 433 |
| User is 310 lines (Critical) | **CONFIRMED** | `wc -l user.rb` = 310 |
| ContestsController is ~889 lines | **CONFIRMED** | `wc -l contests_controller.rb` = 874 (close enough) |
| Username missing unique DB index | **CONFIRMED** | `grep schema.rb` for `index ["username"]` returns nothing |
| `Game#score_affected_contests!` synchronous fanout | **CONFIRMED** | `game.rb:28,32` — called from `after_update`-style hook, sync |
| Entry score stored as Float (line 79 schema) | **CONFIRMED** | `t.float "score"` in schema |
| Selection uniqueness has DB index | **REVISED — agent was wrong** | `schema.rb:273` has `unique: true` on `(entry_id, slate_matchup_id)` — selection is safe |
| Contest grade has lock contention | **CONFIRMED** but lower severity | Lock + DB writes are fast; the real risk is RPC calls inside the lock |
| Controllers' "no-pagination" risk | **CONFIRMED** for `generator`, `my`, `index`; `wallet#show` already does `.limit(10)` |
| `OutboundRequest` bloat | **CONFIRMED** — sweeper exists (`schedule.yml`), runs daily, but no overlap guard |
| Cookie domain audit | **N/A** — already fixed in Stage 1 (B3) |

---

## NEW LAUNCH BLOCKER (must fix before mainnet)

### NB1 — `production.rb` overrides queue adapter to `:async`

**File:** `config/environments/production.rb:76` — `config.active_job.queue_adapter = :async`

What this actually does in production today:

1. `TokenPurchaseJob.perform_later` (the job that mints on-chain tokens after a Stripe charge) → enqueued to the in-process `AsyncAdapter` → runs on a thread in the WEB dyno.
2. `StripeDepositJob.perform_later`, `MoonpayDepositJob.perform_later`, all mailers (`deliver_later`), all `*Job.perform_later` calls — same story.
3. Sidekiq cron jobs (`OutboundRequestSweeperJob` via sidekiq-cron) DO go through Sidekiq because sidekiq-cron pushes directly to Sidekiq's Redis queue, bypassing ActiveJob.
4. The `worker: bundle exec sidekiq` dyno is running, consuming Redis bandwidth, but receiving essentially zero work.

The failure modes:

- **Lost jobs on dyno restart.** Heroku restarts dynos at least daily. Any `:async`-queued job in flight or pending is gone. If a TokenPurchaseJob is enqueued from a webhook and the web dyno restarts 5 seconds later, the user paid Stripe and got no tokens.
- **Request starvation.** When `TokenPurchaseJob` is mid-RPC to Solana (can take 5–30s), it's holding a Puma worker thread. With 3 web threads default, two stuck mints = 1 thread left to serve all incoming requests.
- **No retry persistence.** The `retry_on` in `ApplicationJob` works in `:async`, but the retry queue lives in process memory. Dyno restart = retry counter lost.

**Fix (one line):**
```ruby
# config/environments/production.rb:76
config.active_job.queue_adapter = :sidekiq
```

After deploying, confirm: hit a Stripe test-mode checkout, watch `/admin/jobs` for the job appearing under Sidekiq's queue, and confirm the worker dyno picks it up. Then watch for `[tokens] webhook.job_enqueued` log followed by mint signatures.

I haven't pushed this myself because it's a production config change and warrants your eyeballs — and you'll want to deploy it during a quiet window in case something downstream breaks (e.g., a job that was implicitly relying on `:async`'s in-process behavior).

---

## HIGH-SEVERITY REFACTORS (worth doing before serious traffic)

### H1 — Username has no DB unique index (race condition on signup)

**File:** `app/models/user.rb:15`, `db/schema.rb` users table (no `index ["username"]` present)

`validates :username, uniqueness: { case_sensitive: false }` runs in Ruby, with a TOCTOU window between SELECT and INSERT. At 1000 signups/min (mass-launch surge) two concurrent signups picking the same username will both pass validation and both insert.

**Fix:**
```ruby
add_index :users, "LOWER(username)", unique: true, where: "username IS NOT NULL", name: "index_users_on_lower_username"
```
Migration ~10 lines. The `LOWER()` expression index matches Rails' `case_sensitive: false` semantics.

---

### H2 — Entry sybil check + entry_number assignment racy

**Files:** `app/models/entry.rb:53-79,103-130`, controllers also assign `entry_number` (`contests_controller.rb:325-326,345-346,434-435`)

Three call sites recompute `next entry number = entries.where(user, contest).count + 1`. Under concurrent submissions, two POSTs both read count=0, both insert with `entry_number=1`. Anchor's on-chain init constraint catches one of them, but the DB ends up with a duplicate or an orphaned cart entry.

**Fix:**
1. `add_index :entries, [:user_id, :contest_id, :entry_number], unique: true, where: "entry_number IS NOT NULL"`
2. Extract `User#next_entry_number_for(contest)` helper that uses `INSERT … ON CONFLICT … RETURNING entry_number` or wraps in `user.with_lock` (you already do this for sybil; add entry_number assignment under the same lock).
3. Delete the three duplicate call sites.

---

### H3 — `Game#score_affected_contests!` does synchronous fanout

**File:** `app/models/game.rb:28-36`

When a game's score updates, the callback runs `score_affected_contests!` synchronously: query slate_ids, then score every entry in every affected contest. Real-world worst case at scale: 1 game update → 5 slates → 100 contests/slate → 1000 entries/contest = **500k entry recomputes** inside one HTTP request or admin action. Heroku 30s timeout = guaranteed failure.

**Fix:** Make it a background job — `UpdateGameScoresJob.perform_later(game_id)` (after NB1 ships). The job can iterate at sub-second cost without holding the request open.

---

### H4 — `ContestsController#enter` is 137 lines with 3 interleaved payment paths

**File:** `app/controllers/contests_controller.rb:268-401`

Branches across web2-token, web2-onchain, and web3-phantom payment paths in one mega-action. Three duplicate copies of "next entry number" logic. Vault RPC calls inline. Heavy JSON response building that re-hits the vault for seeds data with silent rescues.

**Fix:** Extract `ContestEntryService` with three strategy classes:
- `TokenFundedEntryFlow` (managed wallet + token consume)
- `OnchainEntryFlow` (Phantom web3 entry)
- `OffchainEntryFlow` (web2 vault transfer)

Each owns its own pre-checks, vault call, and confirm step. Controller becomes ~15 lines: dispatch + render. Seeds reads move to a `UserSeedsSnapshot` value object so they're reusable + testable.

---

### H5 — Entry score column is Float; used for ranking

**Files:** `db/schema.rb:79`, `app/models/contest.rb:~179` (`order(score: :desc)`)

Score = `selections.sum { |s| s.points }` where `points = goals (int) * turf_score (float)`. Float arithmetic introduces tiny non-determinism. Used for ranking entries → payouts. Two entries that "should tie" can break ties unpredictably on float precision.

**Fix:** Migrate to integer `score_milli`. Store `(goals * turf_score * 1000).round`. Display divides by 1000. No more float ranking surprises. The migration is small but invasive (every read site needs adjustment).

---

## MEDIUM-SEVERITY (post-launch backlog, severity-ranked)

| # | Title | Where | Impact |
|---|---|---|---|
| M1 | `User#generate_managed_wallet!` runs synchronously in `after_create` | `user.rb:23` | Blocks signup HTTP request on keypair gen + AES encrypt. Move to `UserOnboardingJob` (after NB1). |
| M2 | `Contest#active_entry_count` queries inside view loops | `contest.rb:418-419` + `contests/index` partials | N+1 on the contest grid. Add `counter_cache: :active_entries_count` on `Entry.belongs_to :contest`. |
| M3 | No pagination on `contests#my`, `#generator`, `#index` | `contests_controller.rb:10,16,42` | Acceptable today (<100 contests). Add kaminari or hand-roll a `limit(50) + cursor`. |
| M4 | Token consume race not under user lock | `contests_controller.rb:318-355` | Same fix as Stage 1 LW5 — wrap in `current_user.with_lock`. (This is the same finding from two angles.) |
| M5 | Composite index `(contest_id, status, user_id)` missing on entries | `db/schema.rb` entries | Existing `(contest_id, status)` falls back to filesort for the user-specific lookups in `Entry#confirm!`. |
| M6 | All Sidekiq jobs on `default` queue | `app/jobs/*` + `Procfile` | After NB1 ships, split into `critical` / `default` / `maintenance` so the sweeper can't delay TokenPurchaseJob. `worker: bundle exec sidekiq -q critical,10 -q default,5 -q maintenance,1` |
| M7 | `ApplicationJob` retries 3x with polynomial backoff | `application_job.rb:2` | Solana RPC flakes 1–3% of the time. 3 attempts = ~10s window. Critical jobs (TokenPurchaseJob) should be `attempts: 25` and have an `on_discard` handler that writes to ErrorLog. |
| M8 | `OutboundRequestSweeperJob` not guarded against overlap | `app/jobs/outbound_request_sweeper_job.rb` + cron | If a run takes >24h (possible on a 10M+ row table during a slow Heroku window) the next run starts while the first is still deleting. Add `Sidekiq.redis.set("sweeper:lock", ttl: 86400, nx: true)` guard. |
| M9 | `MoonpayDepositJob` doesn't re-fetch from MoonPay API | `app/jobs/moonpay_deposit_job.rb` (FIXME in code) | StripeDepositJob has the `StripeCheckoutValidator` re-fetch pattern; MoonPay path trusts the webhook payload. Implement the same re-fetch before mainnet. |

---

## LOW-SEVERITY (won't move the needle but worth noting)

- `Sluggable` concern regenerates slug on every save instead of just on create — wasteful, not buggy
- `Entry#selection_data` includes `:team` but not `:game`; if the view ever calls `s.slate_matchup.locked?` it'll N+1
- `User` table is wide (~1KB/row, dominated by encrypted private key) — extract to `user_wallet_secrets` table for cache density. Premature today.
- `PendingTransaction#metadata` is jsonb with no schema validation — fine for v1
- `TransactionLog#source` is polymorphic without an inclusion validation on `source_type` — add `validates :source_type, inclusion: { in: %w[Contest Entry User StripePurchase] }`
- Inline `render json: { … }` in 40+ places — add Jbuilder templates or serializers when the shape needs to change

---

## SCALING CLIFFS (what breaks first)

| User base | What breaks |
|---|---|
| **Now → 500 DAU** | Nothing structural. The current setup holds. |
| **500 → 1k DAU** | `Entry#confirm!` user-lock contention during peak entry windows (3pm Sunday for sports); 1–3s request latency spikes. `Game#score_affected_contests!` becomes a 30s timeout. |
| **1k → 10k DAU** | Postgres connection ceiling on Heroku Essential-0 (20 connections) — second web dyno saturates the pool. `OutboundRequest` table starts dominating Postgres I/O budget (sweeper falls behind). |
| **10k+ DAU** | Need read replica for leaderboard reads. `Contest#grade!` lock + RPC starts blocking other contest reads. Need partitioning on `outbound_requests` and `transaction_logs` by month. |

---

## Triage recommendation

**This week (before more traffic):**
1. **NB1** — flip `:async` → `:sidekiq` in production.rb. Deploy during a quiet window, watch `/admin/jobs`.
2. **H1** — username unique index migration. 10 lines.
3. **H2** — entry_number unique index + extract `next_entry_number_for(contest)`. Half a day.
4. **M6 + M7** — split Sidekiq queues + bump critical-job retries to 25 with discard alerting. Half a day.

**Next sprint:**
5. **H3** — move game-score fanout to a job.
6. **H4** — extract `ContestEntryService` (this is the biggest win for ongoing development velocity).
7. **M1** — onboarding job.
8. **M9** — MoonPay re-fetch.

**Later (post-launch hardening):**
9. **H5** — score-as-integer migration. Invasive but eliminates a class of payout bugs.
10. Counter caches (M2), pagination (M3), composite indexes (M5).
11. Postgres plan upgrade (Standard-2) before adding a second web dyno.

---

## Open question

Stage 3 (test coverage audit) is queued. Want to:
- Start Stage 3 now (parallel agents over existing test directory)?
- Pause Stage 3 and execute the launch-blocker fixes (NB1, B4 wired today, H1, H2) first?
- Mix — kick off Stage 3 in parallel while you triage these findings?

<!-- citation-guard: snapshot 2026-05-23 (17 citations) — dated refactor audit -->
