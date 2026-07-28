# Turf Monster Workflows

Casual-agent index. Open a per-workflow file for the dirty details (line-cited).

> **Code-first principle.** Workflow files cite `path/to/file.rb:NN` so claims can be
> verified against the current codebase. If a workflow file disagrees with the code,
> trust the code and update the file. Prose rots; line numbers drift on refactor —
> re-confirm before relying on either.

## User journeys

What a player or operator-as-user does end-to-end.

| Workflow | Entrypoint | One-liner |
|---|---|---|
| [submit-entry-decision-tree](submit-entry-decision-tree.md) | Hold to Confirm | THE entry map: web2/web3 × token/USDC/USDT branches, every failure point, funds-stuck inventory, recovery channels + their triggers, mainnet-only gotchas. |
| [web3-landing-to-entry](web3-landing-to-entry.md) | `GET /l/:slug` | Funnel → Phantom signup → on-chain direct entry (USDC). |
| [referral-google-tokens-to-chat](referral-google-tokens-to-chat.md) | `GET /l/:slug` + `?reference=` | Funnel → Google signup → buy 3 tokens → enter → first chat msg. |
| [email-signup-token-to-chat](email-signup-token-to-chat.md) | `GET /` | Root → email signup → buy 1 token → enter main contest → chat. |

## Backend pipelines

Server-side chains: controller → job → external → DB / on-chain.

| Workflow | Entrypoint | One-liner |
|---|---|---|
| _none yet_ | | |

## Operator / admin processes

What a Turf Monster operator does from the admin surface or rake tasks.

| Workflow | Entrypoint | One-liner |
|---|---|---|
| [admin-contest-setup](admin-contest-setup.md) | Phantom login → `GET /contests/new` | Phantom auth → create on-chain Contest PDA → admin enters via Phantom. |
| [market-snapshot](market-snapshot.md) | `bin/rails nfl:expected_team_totals_cache` (🔨 `npm run market-snapshot` planned) | Prefer DK posted team totals, derive from spread + total when absent. |
| [slate-build](slate-build.md) | `Nfl::BuildSpanSlate.call` (🔨 `bin/rails slates:build` planned) | Projections → slate → rank by summed expectation → freeze the multiplier. |

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
