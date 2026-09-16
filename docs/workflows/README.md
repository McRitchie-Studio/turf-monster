# Turf Monster Workflows

Casual-agent index. Open a per-workflow file for the dirty details.

> **Code-first principle.** Every workflow file cites `path/to/file.rb:NN` so claims can be
> verified against the current codebase. If a workflow file disagrees with the code,
> trust the code and update the file. Prose rots; line numbers drift on refactor —
> re-confirm before relying on either.
>
> **Every citation here is checked, and every file gets the strong check.**
> `test/docs/workflow_citation_docs_test.rb` reads every file in this directory and
> proves, for every citation: the file it names exists, the line it names is inside
> that file, the lines it names are not all blank — and that the citation lands on
> the SYMBOL its prose names, which is what catches a number that merely moved.
> Since 2026-09-09 every workflow file is in that test's `COVERAGE`; a new file is a
> red test until it is swept and opted in (see [`_TEMPLATE.md`](_TEMPLATE.md)).
>
> **Strong is not uniform.** Where a cited line sits inside no definition the guard
> can derive — ERB markup, a `.js` or `.rake` file, a class-body callback —
> the check falls back to asking that a code token the prose quotes appear in the
> cited lines. That proves the words are there, not that the code is. Each file's own
> preamble states how many of its citations get the weaker check, and the test holds
> it to that number. And no check reads PROSE: a citation can land on the right
> symbol beside a sentence that is no longer true.
>
> **A bare word must also be RARE where it lands** (2026-09-15). The fallback used to
> accept any quoted token of six characters or more that appeared anywhere in the
> cited lines, and a citation that had drifted onto buffer-rent arithmetic stayed
> green because that line held the word `upgrade`. A token with no structure — no
> `_`, `::`, `#`, `.`, `-`, no camelCase, no digit — is now matched whole AND must
> occur on no more than twelve lines of the file it points into; `upgrade` was on 22
> of that file's 947, so the number could have been any of them. Structured names
> (`EXPECTED_IDL_HASH`, `Solana::Config.verify_idl!`) are specific by construction and
> are not capped.
>
> **A `config/routes.rb` citation anchors on its FIRST line** (2026-09-16). A routes
> file's cited lines are `draw do` entries, not method bodies, so no citation into
> it reaches the symbol check —
> every one of them fell to the fallback, and a routes stanza repeats its own words
> often enough that a span which had slipped a line still held a token. One inserted
> route moved five citations in three documents and all five stayed green, one of
> them opening on a blank line and dropping two of the three routes its prose named.
> A route entry is ONE line, so the number must land on it; the one exemption is a
> citation of a routes COMMENT, which must name the whole comment block rather than
> part of one. Measured: a one-line insertion now reddens 19 of the 21 routes
> citations, a deletion 17.
>
> **Every document under `docs/` now says whether it is guarded** (2026-09-15).
> Until then this directory was the whole of the scope, and the other eleven
> citation-carrying documents in `docs/` were unguarded for the sole reason that
> nobody had mentioned them — which looked exactly like a document deliberately
> frozen. Each one now ends with a declaration, and the guard's inventory test
> fails on any document that carries `path:line` citations and declares nothing:
>
> | Declaration | Means |
> |---|---|
> | `<!-- citation-guard: enforced -->` | under EVERY check, the symbol check included — what every file in this directory carries |
> | `<!-- citation-guard: snapshot <date> (<N> citations) -->` | a dated audit; its citations are true as of that date and are frozen |
> | `<!-- citation-guard: external (<N> citations) — … -->` | names a repository this one cannot read, so no line number here is checkable |
> | `<!-- citation-guard: unswept (<N> citations) — … -->` | live citations nobody has verified — a confession, not a pass, from a pinned list of documents |
>
> An exemption states its own citation count and the guard holds it exactly, so a
> frozen document cannot quietly acquire new unchecked coordinates. The marker goes
> at the END of the file, and the guard now checks that it is the last line: the
> parser reads the LAST marker in a document, and `SOLANA.md` and `FORMULAS.md` are
> cited BY LINE from other documents, so a declaration must not move the thing it
> declares.
>
> **`enforced` means one strength** (2026-09-16). Until then it bought the three
> coordinate checks and not the symbol check, which reads only `COVERAGE` —
> `docs/AUTH.md` wore the badge while seven of its ten citations failed the symbol
> check nobody was running. The guard now holds the documents declaring `enforced`
> EQUAL to `COVERAGE`, both ways, and holds the documents declaring `unswept` equal
> to a pinned list (`UNSWEPT_DOCS`), so a new document cannot go green by confessing.

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
