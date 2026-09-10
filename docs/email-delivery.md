# Email Delivery - SES Primary, Resend Rollback

Turf Monster sends transactional email through ActionMailer: magic-link sign-in,
verification, wallet export, email-change, contest winnings, and newsletter
welcome. App code calls `Studio::Email.deliver`; the shared facade delegates to
Turf's existing top-level `EmailDelivery` outbox, so every send is recorded as
an audit row.

Cross-app sender inventory, SES cutover rules, local inbox proof, and rollback
policy live in `mcritchie-studio/docs/agents/modules/email-operations.md`. Keep
this file focused on Turf-specific wiring.

## Transport Switch

The active transport is chosen by `MAIL_TRANSPORT` (`ses` | `resend`). `ses` is
the target state; Resend remains a rollback path while SES adoption is proved.
Turf uses the shared Studio engine mail transport:

| `MAIL_TRANSPORT` | Active transport | Notes |
|---|---|---|
| `ses` with SES creds | SES SMTP | Target state. Requires `SES_SMTP_USERNAME`, `SES_SMTP_PASSWORD`, `SES_REGION`. |
| `ses` without SES creds | Resend fallback | Logs a warning; avoids silently breaking login during setup. |
| unset / `resend` | Resend | Rollback path while the Resend account remains available. |

- `config/initializers/studio_mail_transport.rb` calls `Studio::MailTransport.configure!`.
- `studio-engine` owns `Studio::MailTransport`, `Studio::Email.deliver`, the
  Resend dependency, and the shared `ses:*` Rake tasks.
- `MAILER_FROM` and `MARKETING_MAILER_FROM` are the app-branded SES senders.
- `RESEND_MAILER_FROM` is the shared fallback sender. While SES is blocked by
  sandbox/presetup, Resend sends from `McRitchie Studio
  <team@mcritchie.studio>` instead of requiring another paid Resend domain.
  That domain must be verified in the active Resend account; do not swap the
  fallback sender to `team@turfmonster.media` unless `turfmonster.media` is
  also present and verified in Resend.
- SES transactional/auth/security/contest email uses `Turf Monster <team@turfmonster.media>`.
- SES newsletter/marketing email uses `Alex from Turf Monster <alex@turfmonster.media>`.
- Tests always use `:test` in memory; the transport no-ops in `Rails.env.test?`.

SES account/domain checks should use `SES_AWS_ACCESS_KEY_ID` and
`SES_AWS_SECRET_ACCESS_KEY` from `agent.aws.mcritchie-ses`. Do not overwrite
Turf's existing S3 or app-level `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
unless that IAM user is deliberately being rotated.

## Local Email Delivery

Primary local stacks send real email through the configured provider by default.
Keep `LOCAL_EMAIL_CAPTURE=0` in the primary `.env` when testing sign-in or
transactional flows locally. While SES production access is pending, that means
Resend sends from `McRitchie Studio <team@mcritchie.studio>`.

In non-production, `studio-engine` also exposes a local inbox:

```text
http://localhost:3100/_studio/local_emails
```

Worktree stacks launched through McRitchie Studio's `bin/agent-worktree` still
set `LOCAL_EMAIL_CAPTURE=1` and blank provider mail credentials in
`.env.agent-stack`. In that mode `Studio::Email.deliver` still records Turf's
`email_deliveries` rows, but `EmailDeliveryJob` is not enqueued and
`deliver_now!` refuses to send. Agents should use the inbox URL as the proof
surface for magic-link/auth work instead of asking the user to check Gmail.

Set `LOCAL_EMAIL_CAPTURE=1` only when intentionally using local inbox capture.

## Durable Delivery

Turf Monster keeps its existing `email_deliveries` table and `EmailDeliveryJob`.
The shared `Studio::Email.deliver` facade uses that app-level adapter first, so
Turf can align call sites with McRitchie Studio without moving production data
into `studio_email_deliveries` yet.

### Recovering stranded rows

`EmailDeliveryResendJob` runs every 20 minutes (`config/schedule.yml`) and
re-enqueues rows still `sent: false`. It exists for the silent failure Sidekiq
cannot cover: a row left unsent with no job anywhere, which on 2026-09-07 left a
paid contest winner untold. It is bounded on purpose — rows younger than 30
minutes are still in flight, rows older than 7 days are counted in its log line
and left for a human, and at most 100 go per tick so a backlog drains across
ticks. It no-ops entirely where `Studio.local_email_capture?` is true, since
nothing there can ever reach `sent`.

`EmailDelivery.resend_unsent!` remains the by-hand escape hatch, and it has **no
bounds at all** — it re-enqueues every unsent row in the table, months-old
"you won" mail included, and that mail cannot be unsent. Let the sweep drain a
backlog; reach for `resend_unsent!` only after counting what it would send.

## Cutover Checklist

Use the shared checklist in
`mcritchie-studio/docs/agents/modules/email-operations.md` first, then apply the
Turf-specific values below.

Current production status, last checked 2026-06-15:

- SES account in `us-east-2`: sending enabled, enforcement healthy, still in
  sandbox (`ProductionAccessEnabled=false`).
- `turfmonster.media`: verified for sending, DKIM `SUCCESS`.
- Resend fallback domain: `mcritchie.studio` is verified in the Resend account
  backing production apps.
- Persistent production transport: keep Resend active from `McRitchie Studio
  <team@mcritchie.studio>` until SES production access is approved.
- Production app adoption: `studio-engine 0.5.9` is deployed on
  `turf-monster-mainnet`.
- Last production proof: Heroku release `v90` booted with
  `[mail] transport=Resend from=McRitchie Studio <team@mcritchie.studio>`,
  accepted public health/contest requests, and keeps Sidekiq as the production
  job backend for `EmailDeliveryJob`.

### Prerequisites

1. SES production access is approved in `us-east-2`; sandbox mode can send only
   to verified recipients.
2. `turfmonster.media` is verified in SES with DKIM. Run
   `bin/rails "ses:verify_domain[turfmonster.media]"` to print the records.
3. SPF includes Amazon SES, and DMARC exists for `turfmonster.media`.
4. SES SMTP creds are staged on Heroku: `SES_SMTP_USERNAME`,
   `SES_SMTP_PASSWORD`, `SES_REGION`.
5. `MAILER_FROM="Turf Monster <team@turfmonster.media>"` is set.
6. `MARKETING_MAILER_FROM="Alex from Turf Monster <alex@turfmonster.media>"` is set for newsletter/marketing mail.
7. `RESEND_MAILER_FROM="McRitchie Studio <team@mcritchie.studio>"` is set for rollback/presetup mail.

Verify state any time:

```bash
bin/rails ses:check
```

### Cutover

```bash
heroku config:set -a turf-monster-mainnet \
  SES_SMTP_USERNAME=... SES_SMTP_PASSWORD=... SES_REGION=us-east-2
heroku config:set -a turf-monster-mainnet \
  MAILER_FROM="Turf Monster <team@turfmonster.media>" \
  MARKETING_MAILER_FROM="Alex from Turf Monster <alex@turfmonster.media>" \
  RESEND_MAILER_FROM="McRitchie Studio <team@mcritchie.studio>"
heroku config:set -a turf-monster-mainnet MAIL_TRANSPORT=ses
```

Smoke test the provider with `bin/rails "email:smoke[approved-test-inbox@example.com]"`,
then smoke test a production magic link and confirm delivery plus DKIM/SPF/DMARC
pass.

For Resend fallback proof, check both sides:

1. The app request returns success.
2. The durable outbox job finishes without provider error.
3. The message arrives in the target inbox or spam.

If Resend returns "domain is not verified", verify `mcritchie.studio` in the
Resend account before retrying; changing `RESEND_MAILER_FROM` to an unverified
app domain only moves the failure.

### Rollback

```bash
heroku config:unset -a turf-monster-mainnet MAIL_TRANSPORT
```

Resend resumes if `RESEND_API_KEY` is present.

### Decommission

Follow the shared decommission criteria before canceling Resend or dropping
`RESEND_API_KEY`.

## Engine Ownership

Turf Monster currently uses `studio-engine 0.5.9`. Keep future shared transport,
delivery facade, local agent inbox, and provider smoke-test changes in
`studio-engine`; keep Turf-specific catalog entries, previews, and email copy in
the app.
