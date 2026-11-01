# Operator API: the hub's contest operations

The McRitchie Studio hub's Turf agent reads contests and runs a named operation
here once Alex McRitchie confirms it with `go` in a Slack or Discord thread. The
hub side (the `operate` catalog, the confirm, the run record) is documented in
mcritchie-studio `docs/agents/system/agent-message-loop.md`, "Operations".

| Route | What it does | Writes |
|-------|--------------|--------|
| `GET /_operator/contests?scope=open\|all&limit=1-25` | Recent contests: slug, name, status, cancelled, cancel queued, weeks, format, lock, entries, paid entries | nothing |
| `POST /_operator/contests/:slug/cancel` (`paid_entries` none\|refund\|credit, `requested_by`, `request_ref`) | `Contests::CancelQueue`, the admin button's own build (`ContestsController#cancel_onchain`): a `cancel_contest` PendingTransaction for a cosign in the Treasury | one PendingTransaction, or none when one is already waiting |
| `POST /_operator/contests/prepare` (`week` 1-22, `weeks` 1-3, `season` regular\|preseason, `contest_type`) | Checks every week of the span has a weekly NFL slate and returns the pre-filled `/contests/new` link | nothing |

**Auth.** `Authorization: Bearer $TURF_OPERATOR_TOKEN`, compared in constant time.
With the variable unset every request is a bare 404. The hub holds the same value
as `OPERATOR_TOKEN_TURF_MONSTER`. It is its own token, never the read-only
`STUDIO_HEALTH_TOKEN`. 1Password: `turf.operator.token` (Steffon files it,
`credential-filing`).

**What no operation does.** None signs or broadcasts a transaction. A cancel is
pre-signed in the admin (payer) slot only, as the button always was, and ends at
an owner's wallet in `/admin/pending_transactions` (AGENTS.md First Rule 10). A
create is a link: the admin reviews the form and signs `create_contest` in
Phantom, funding the prize pool from their own wallet.

**Paid entries.** A cancel of a contest with paid entries (`Contest.paid_entries`)
is refused (`422`, `paid_entries_need_choice`) until the request names `refund`
or `credit`. The choice is recorded on the PendingTransaction's metadata. Making
the entrants whole stays a human step: `docs/runbooks/cancelled-contest-refunds.md`.

**Answers.** JSON with `schema: 1`. A refusal is `422` with a stable `error` code
(`not_found`, `not_cancellable`, `paid_entries_need_choice`, `bad_choice`,
`no_slate`, `bad_week`, `bad_weeks`, `bad_season`, `bad_format`) and operator
copy in `message`. Anything else is an ErrorLog row and a `500` with no message.
