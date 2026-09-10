# Turf Monster Workflows

Casual-agent index. Open a per-workflow file for the dirty details.

> **Code-first principle.** Most workflow files cite `path/to/file.rb:NN` so claims can be
> verified against the current codebase. If a workflow file disagrees with the code,
> trust the code and update the file. Prose rots; line numbers drift on refactor —
> re-confirm before relying on either.
>
> **Two workflow files cite nothing at all.** Measured 2026-09-09, [live-scoring](live-scoring.md)
> and [submit-entry-decision-tree](submit-entry-decision-tree.md) parse to zero citations
> each. They name symbols throughout and point at none of them, so every claim in those
> two is unverified prose. Check them against the code before you rely on either.
>
> **Every cited file here is checked — but not to the same depth.**
> `test/docs/workflow_citation_docs_test.rb` reads EVERY file in this directory and
> proves three things about every citation in it: the file it names exists, the line it
> names is inside that file, and the lines it names are not all blank. So a coordinate
> that points at nothing is now a red test, wherever it is written.
>
> The stronger check — that a citation lands on the SYMBOL its prose names, which is what
> catches a number that merely moved — still runs only on the documents listed in that
> test's `COVERAGE`: today [web3-landing-to-entry](web3-landing-to-entry.md) and
> [market-snapshot](market-snapshot.md). Turning it on everywhere is a citation sweep, not
> a test change: measured 2026-09-09, 265 of the 323 citations in the other four cited
> files would fail it. Until they are swept, read a number in those four as a real
> coordinate that has been bounds-checked, not as a verified claim about the code at it.
> And a `COVERAGE` file is not uniformly guarded either: each one's own preamble states
> which of its citations get the weaker of the two checks.

## User journeys

What a player or operator-as-user does end-to-end.

| Workflow | Entrypoint | One-liner |
|---|---|---|
| [submit-entry-decision-tree](submit-entry-decision-tree.md) | Hold to Confirm | THE entry map: web2/web3 × token/USDC/USDT branches, every failure point, funds-stuck inventory, recovery channels + their triggers, mainnet-only gotchas. |
| [web3-landing-to-entry](web3-landing-to-entry.md) | `GET /lp/:slug` | Funnel → Phantom signup → on-chain direct entry (USDC). |
| [referral-google-tokens-to-chat](referral-google-tokens-to-chat.md) | `GET /lp/:slug` + `?reference=` | Funnel → Google signup → buy 3 tokens → enter → first chat msg. |
| [email-signup-token-to-chat](email-signup-token-to-chat.md) | `GET /` | Root → email signup → buy 1 token → enter main contest → chat. |

## Backend pipelines

Server-side chains: controller → job → external → DB / on-chain.

| Workflow | Entrypoint | One-liner |
|---|---|---|
| [live-scoring](live-scoring.md) | `bin/nfl-live-poll` | Poll ESPN → write Goals → re-score open contests → broadcast. |

## Operator / admin processes

What a Turf Monster operator does from the admin surface or rake tasks.

| Workflow | Entrypoint | One-liner |
|---|---|---|
| [admin-contest-setup](admin-contest-setup.md) | Phantom login → `GET /contests/new` | Phantom auth → create on-chain Contest PDA → admin enters via Phantom. |
| [market-snapshot](market-snapshot.md) | `bin/rails nfl:expected_team_totals_cache` | Prefer DK posted team totals, derive from spread + total when absent. |
| [slate-build](slate-build.md) | `Nfl::BuildSpanSlate.call` | Projections → slate → rank by summed expectation → freeze the multiplier. |

## Dev / deploy

Local development, devnet proof, prod deploys, and IDL re-pin. Current Solana
proof lives in `docs/SOLANA.md`, `docs/SECURITY_REVIEW.md`, and
`turf-vault/docs/VERIFICATION_MATRIX.md`; retired rehearsal runbooks are
historical only.

| Workflow | Entrypoint | One-liner |
|---|---|---|
| _none yet_ | | |

---

## Conventions

- **File names:** kebab-case action phrases (`buy-tokens`, `settle-contest`, `deploy-vault-squads`).
- **Cross-links:** inside a workflow doc, reference siblings with `[[slug]]` (matches the file basename).
- **One-liner column:** ≤ 80 chars, lead with the verb. Skim-friendly.
- **Entrypoint column:** a route (`POST /tokens`), button (`#buy-tokens-cta`), job (`CreditTokensJob`), or command (`bin/dev`).
- **New workflows:** copy [`_TEMPLATE.md`](_TEMPLATE.md), fill it in, then add a row above.
- **Stale check:** when a controller / model / job referenced here is renamed or moved, the workflow file is wrong until the citation is updated.
