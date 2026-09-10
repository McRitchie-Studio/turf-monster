# Workflow: <name>

> **Code is law.** Every claim below cites `path/to/file.rb:NN` from the current
> codebase, and a bare `:NN` inherits the nearest preceding path — file context resets
> at each `##` heading. The number is bookkeeping; the SYMBOL beside it is the claim, and
> `test/docs/workflow_citation_docs_test.rb` reddens when a citation stops landing inside
> the definition its prose names.
> That symbol check reaches **N of the M citations** here. The other **K** ride the
> weaker literal fallback — <say which files or shapes, and why>.

**Trigger:** <what kicks it off — route, button click, background job, cron, webhook, manual rake task>
**Actors:** <User / Operator / Sidekiq / Stripe / Resend / Solana RPC / Squads / Phantom / ...>
**Outcome:** <state changes when it succeeds — DB rows written, on-chain PDAs touched, emails/webhooks sent>
**Preconditions:** <what must be true before the trigger fires — user logged in, contest open, balance >= fee>

## Sequence

1. **<step name>** — `path/to/file.rb:NN`
   - <one-line elaboration if behaviour is non-obvious>
2. **<step name>** — `path/to/controller.rb:NN`
   - enqueues `SomeJob` → `app/jobs/some_job.rb:NN`
3. **<step name>** — `path/to/service.rb:NN`
   - calls external <Stripe / Solana RPC / Resend>
4. ...

## Data touched

- `table_name.column` (read / write / insert / update)
- `another_table` (insert)
- on-chain: `<PDA name / instruction>` (read / cpi / sign+send)
- external: <Stripe payment intent / Resend email / Sentry event>

## Failure modes

- **<failure case>** — user-visible symptom → where it surfaces (log line, table, dashboard, Sentry)
- **<failure case>** — what the code does (retry / dead-letter / silent skip) → operator action required
- ...

## Related workflows

- [[other-workflow-slug]] — <how they connect — predecessor, successor, alternate path>

---

<!--
How to use this template:
- Copy to `docs/workflows/<kebab-case-name>.md`.
- Fill in every angle-bracket placeholder; delete any section that doesn't apply (rare).
- Cite file:line for EVERY step. Run `grep -n` if you forget the number; do not guess.
- NAME THE SYMBOL beside every citation. Where the cited line sits inside a method (or an
  inline-JS member in an `.erb`), the prose unit around the citation — its own list item
  plus every parent item, or its paragraph — must name that method, e.g. `Klass#method`.
  Where it sits inside no definition, quote a code token (6+ characters) that appears in
  the cited lines.
- A bare `:NN` inherits the last PATH-QUALIFIED citation, not the last file you
  mentioned: a path written without a line number is not a citation and sets nothing.
- Opt the file into `COVERAGE` in `test/docs/workflow_citation_docs_test.rb` — a new
  workflow file is a red test until you do. Measure it with that test's own parser, set
  `min_citations` / `min_path` / `min_bare` just below the measured counts, and fill in
  the **N of the M** / **K** numbers above from the same measurement.
- Add a row to `docs/workflows/README.md` under the right category.
- If this workflow chains into another, add the [[slug]] cross-link both ways.
-->
