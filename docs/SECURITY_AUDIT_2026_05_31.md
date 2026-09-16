# Security Audit — Adversarial (Lazarus-persona) Review

> **ARCHIVE-ONLY AUDIT SNAPSHOT.** This adversarial May 2026 report predates later TX verification, LogRocket/session replay, auth, Solana, and release hardening. Start from `docs/SECURITY_REVIEW.md`, current app docs, and current code before reviving any finding below.

**Date:** 2026-05-31  
**Scope:** `turf-monster` (Rails app) · `turf-vault` (Anchor program) · `solana-studio` (crypto gem)  
**Predecessor:** [`SECURITY_AUDIT_2026_05_23.md`](SECURITY_AUDIT_2026_05_23.md)  
**Contract companion:** [`turf-vault/docs/SECURITY_AUDIT_2026_05_31.md`](../../turf-vault/docs/SECURITY_AUDIT_2026_05_31.md)  
**Method:** Multi-agent adversarial audit — 11 finder agents in a financially-motivated-APT persona across 11 attack dimensions, every finding independently refuted by skeptic agents (2 perspective-diverse verifiers for critical/high: one reachability, one correctness), then deduplicated, severity-normalized, and ranked by deploy risk. 67 agents total.

---

## 🔴 Verdict: **BLOCK**

Two confirmed critical findings each enable theft of value or keys with no privileged precondition beyond what an ordinary user already has. TXVERIFY-1: any normal Phantom-authenticated user can mint free, ranked, payout-eligible entries into paid, operator-funded contests by stamping an arbitrary finalized signature — direct value forgery, no admin role. KEY-1: every legitimate wallet-export streams a decrypted private key (plus the owner's email) to LogRocket, a self-inflicted plaintext key-exfiltration channel that defeats the entire at-rest-encryption/log-redaction design. Either alone justifies blocking. Additionally, TV-1/FUND-1 (high) lets a settle-authority redirect an entire prize pool to an arbitrary ATA, and AUTH-2 (high) escalates a single hijacked session to full custodial-key theft. The on-chain state-machine highs (STATE-1/STATE-2 cluster) let a single 1-of-3 server key re-open locked contests for results-known entries. These confirmed critical/high fund- and key-theft paths are open, so this is a clear BLOCK; reassess to conditional-go once TXVERIFY-1 and KEY-1 are remediated and the settle/state-machine highs are scheduled.

**Counts (post-verification):** 43 findings hunted · **30 confirmed** · 5 uncertain · 8 refuted (dropped).

---

## Executive summary

This adversarial audit of the turf-monster Rails app, turf-vault Anchor program, and solana-studio gem surfaced two CONFIRMED critical issues that enable fund/key compromise and must be fixed before deploy, plus a cluster of high/medium on-chain authority and state-machine weaknesses.

The two showstoppers: (1) recover_pending_entry (TXVERIFY-1) activates a paid, payout-eligible on-chain contest entry from ANY client-supplied finalized transaction signature with no semantic verification — a normal Phantom-authed user gets free entries into operator-funded prize pools; (2) the wallet-export reveal page (KEY-1) renders decrypted private keys into the DOM under the default layout that unconditionally loads LogRocket session-replay, streaming full Ed25519 secret keys (labeled with the owner's email via identify()) to a third party on every export.

On the program side, settle_contest pays each winner to a fully unconstrained destination ATA (TV-1/FUND-1, high) and the contest lifecycle has no real time-based gating: settle ignores lock/conclusion timestamps (STATE-1/STATE-5), and a single 1-of-3 signer can re-open a locked contest or clear its conclusion (STATE-2/STATE-3/STATE-4) — enabling late, results-known entries. A passwordless-account re-auth gap (AUTH-2, high) lets a single hijacked session escalate to recovery-email takeover and full custodial-key export.

Several finder claims were refuted under verification (notably the entry-flow self-custody guard KEY-2, the proof-of-reserves XSS POR-1, and the token-tier value-forgery ETK-1/FUND-4, all of which had guards or design constraints the finders missed) and are recorded in the appendix. Recommendation: BLOCK until TXVERIFY-1 and KEY-1 are fixed; the on-chain settle/state-machine highs should ship in the same hardening pass.

---

## Findings at a glance

| # | Sev | Status | Component | Title | Fix |
|---|-----|--------|-----------|-------|-----|
| 1 | 🔴 critical | confirmed | turf-monster | recover_pending_entry activates a paid on-chain entry from any client-supplied tx signature with no semantic verification (free, payout-eligible entries) | small |
| 2 | 🔴 critical | confirmed | turf-monster | Wallet-export reveal page streams decrypted private keys (plus owner email) to LogRocket third-party session replay | small |
| 3 | 🟠 high | confirmed | turf-vault | settle_contest pays each winner to a fully unconstrained destination ATA — prize pool redirectable to any USDC account | small |
| 4 | 🟠 high | confirmed | turf-monster | Email change and first-password set require no re-auth for passwordless accounts — single hijacked session escalates to recovery-email + custodial-key takeover | medium |
| 5 | 🟠 high | confirmed | turf-vault | set_contest_lock_time / set_contest_conclusion_time (1-of-3) can re-open a locked contest or clear its conclusion, enabling late results-known entries | small |
| 6 | 🟡 medium | confirmed | turf-vault | settle_contest has no lock/conclusion-time precondition — a contest can be graded while still open for entries and before it concludes | small |
| 7 | 🟡 medium | confirmed | turf-monster | Entry#confirm_onchain! has no entry-fee payment gate (unlike Entry#confirm!) — model fails open if a caller skips verification | small |
| 8 | 🟡 medium | confirmed | turf-monster | No uniqueness / replay guard on onchain_tx_signature anywhere (DB, model, or verifier) — one real signature can credit multiple DB rows | small |
| 9 | 🟠 high | confirmed | turf-vault | mint_entry_token forges spendable free entries at 1-of-3 and has no on-chain source_ref idempotency despite docs claiming it | medium |
| 10 | 🟡 medium | confirmed | turf-monster | Chargeback/refund does not revoke already-minted on-chain entry tokens or gate settlement on frozen?; operator absorbs fraud loss | medium |
| 11 | 🟡 medium | confirmed | turf-monster | Production Rails.cache is per-process :memory_store, silently degrading magic-link single-use replay protection and rack-attack throttles | trivial |
| 12 | 🔵 low | confirmed | turf-monster | MoonPay webhook trusts attacker-controllable payload amount with no API re-fetch (latent value-forgery) | small |
| 13 | 🔵 low | uncertain | turf-monster | merge_users! transfers credentials and pivots the session to the lower-id account without rotating session_token | small |
| 14 | 🔵 low | confirmed | turf-monster | Wallet-export reveal page (#show) skips authentication and omits the Referrer-Policy / Cache-Control hardening that #consume sets | trivial |
| 15 | 🔵 low | confirmed | turf-monster | Email uniqueness is case-sensitive in DB/model while auth lookups normalize to lowercase — account-confusion / dual-identity surface | small |
| 16 | 🔵 low | confirmed | turf-monster | CSP allows 'unsafe-inline' + 'unsafe-eval' on script-src — any future HTML-injection sink becomes executable XSS on the fund-handling origin | medium |
| 17 | 🔵 low | confirmed | turf-monster | Sidekiq Web admin gate checks role but skips the OPSEC-045 session-token revocation check | trivial |
| 18 | ⚪ info | confirmed | turf-monster | email_verification tokens have no single-use/replay protection (24h replayable signed token) | small |
| 19 | 🔵 low | confirmed | turf-vault | Operator revenue commingled in one per-mint ATA; per-contest entry_fees tallies are advisory and can drift from real balances | medium |
| 20 | 🔵 low | uncertain | turf-monster | Jurisdiction (geo) gating trusts request.remote_ip and is the only server-side enforcement of restricted-state blocking | medium |
| 21 | 🔵 low | confirmed | turf-monster | tokens/dev_mint route drawn in production (free on-chain token mint endpoint), relies solely on controller triple-gate | trivial |
| 22 | 🔵 low | confirmed | solana-studio | Borsh decoder silently truncates / type-confuses on short or crafted account data; out-of-range offset raises uncatchable-by-contract NoMethodError | small |
| 23 | 🔵 low | uncertain | solana-studio | AuthVerifier nonce-expiry check is silently skipped when nonce_at is nil (fail-open API) | trivial |
| 24 | 🔵 low | confirmed | turf-monster | stamp_entry_signature authorizes via nil==nil for a null-initiator PendingTransaction (latent IDOR) | trivial |
| 25 | ⚪ info | uncertain | turf-vault | settle_contest remaining-account user/entry PDAs not checked for program ownership before deserialize/mutation | trivial |
| 26 | ⚪ info | uncertain | turf-vault | entry_token is not PDA-seed-bound in enter_contest_with_token — validated only by a self-asserted owner field | small |
| 27 | ⚪ info | confirmed | turf-monster | admin/usdc_balance is the one AdminController action excluded from require_admin (reachable by any logged-in user, but self-only) | trivial |
| 28 | ⚪ info | confirmed | turf-vault | Mainnet build hard-codes declare_id! to the System Program ID placeholder | trivial |
| 29 | 🔵 low | confirmed | turf-vault | mint_entry_token idempotency keyed on caller-supplied sequence, not source_ref — operator-side double-mint of free entries | small |

---

## Cross-cutting themes

- Rails trusts client-supplied transaction signatures without binding them to the credited row: recover_pending_entry (rank 1) accepts any finalized signature with no TxVerifier call, Entry#confirm_onchain! has no payment gate (rank 7), and there is no signature-uniqueness/replay guard anywhere (rank 8). The verification primitive (TxVerifier with server-re-derived PDAs) exists and is used on the live path but is bypassed on the recovery path.
- On-chain authority checks verify some accounts but not the security-critical one: settle_contest PDA-verifies the user and entry accounts but leaves the payout DESTINATION ATA fully unconstrained (rank 3) — the same omission pattern (validate-most-but-not-all) that the spec said to avoid, while sibling instructions (cancel_contest, sweep_operator_revenue) do bind their destinations.
- Privilege tiering is inconsistent on the vault: value-forging and fund-fairness operations sit at 1-of-3 (mint_entry_token rank 9/29; set_contest_lock_time / set_contest_conclusion_time rank 5) — driven by the always-online Alex Bot server key — while only settle/cancel/sweep require 2-of-3. A single compromised server key thus forges spendable value and manipulates contest timing.
- The contest state machine has no enforced time boundary tying 'entries closed' to 'grading allowed': Locked status is vestigial, settle ignores lock/conclusion timestamps (rank 6), the lock is freely re-openable and the conclusion freely clearable/postponable (rank 5), and timestamps accept past/negative values. The v0.18 'conclusion finality' story is non-binding for the operations it was meant to protect.
- Self-inflicted secret/PII exfiltration to third parties via the default layout: LogRocket session-replay is loaded unconditionally in all environments with no DOM/text sanitization and labels every replay with the user's email, defeating the at-rest-encryption/log-redaction design precisely on the key-reveal page (rank 2/14). Documentation repeatedly contradicts the shipped behavior (magic_link/rack_attack comments claim Redis while prod ships memory_store rank 11; CLAUDE.md claims source_ref idempotency that does not exist on-chain rank 9/29) — operators are lulled into trusting guards that aren't there.
- Auth re-authentication and identity invariants are weak for the dominant passwordless/managed-wallet user class: has_password?-gated re-auth becomes a no-op for those users (rank 4), email uniqueness is case-sensitive while lookups normalize (rank 15), and session-token revocation does not extend to the Sidekiq dashboard (rank 17) — so a single session compromise can chain to recovery-email + custodial-key theft.
- Latent/conditional foot-guns that activate on a benign ops change: per-process memory_store breaks magic-link single-use the instant web concurrency goes above 1 (rank 11), dev_mint is in the prod route table awaiting only an env misconfiguration (rank 21), and the stamp_entry_signature nil==nil authz becomes a live IDOR the moment a null-initiator PendingTransaction is introduced (rank 24).
- The solana-studio decoder and verifier helpers fail open rather than closed (Borsh silent truncation / uncatchable NoMethodError rank 22; AuthVerifier nonce-expiry skipped on nil timestamp rank 23) — currently bounded by trusted RPC/atomic-session preconditions, but they are library-level robustness gaps that become live for any future or third-party consumer.

---

## Detailed findings

### 🔴 #1 — recover_pending_entry activates a paid on-chain entry from any client-supplied tx signature with no semantic verification (free, payout-eligible entries)

- **Severity:** CRITICAL · **Status:** confirmed · **Component:** `turf-monster` · **Fix effort:** small
- **Location:** `app/controllers/contests_controller.rb:620-683 (recover_pending_entry), :597-608 (stamp_entry_signature); app/models/entry.rb:167-203 (confirm_onchain!, no payment gate)`

**Attack scenario**

A normal Phantom-authed user (no admin role): POST toggle_selection to build a 6-pick cart entry on a paid on-chain contest; POST prepare_entry (server persists a pending PendingTransaction with metadata.entry_pda, broadcasts nothing); POST stamp_entry_signature with ptx_slug + ANY successful finalized Solana signature (e.g. a 1-lamport self-transfer, or literally anyone's confirmed tx — the only gate is ptx.initiator_address == own web3 address); POST recover_pending_entry — the handler calls client.confirm_transaction (getSignatureStatuses with searchTransactionHistory:true), which returns success/finalized for ANY real tx, then calls entry.confirm_onchain! with no TxVerifier call and no PDA re-derivation. Entry flips to :active, ranked and payout-eligible, with zero USDC transferred to the vault. Repeat up to max_entries_per_user across every open paid contest.

**Impact**

Direct value forgery: free, ranked, payout-eligible entries into operator-funded paid prize pools without paying the vault. Scales across every open on-chain contest and every account; either steals prize-pool share on win or forces the operator to subsidize pools while collecting no entry fees.

**Fix (small)**

In recover_pending_entry, replace the bare confirm_transaction success check with Solana::TxVerifier.verify!(signature:, instruction_name: 'enter_contest', signer_pubkey: current_user.web3_solana_address, writable_pubkey: server-re-derived entry PDA) — the same control confirm_onchain_entry already uses (line 704). Re-derive the entry PDA server-side from (contest.slug, wallet, entry.entry_number); do not trust ptx.metadata.entry_pda. Also add a payment gate to Entry#confirm_onchain! mirroring Entry#confirm! (see rank 6) so the model fails closed if any caller skips verification.

---

### 🔴 #2 — Wallet-export reveal page streams decrypted private keys (plus owner email) to LogRocket third-party session replay

- **Severity:** CRITICAL · **Status:** confirmed · **Component:** `turf-monster` · **Fix effort:** small
- **Location:** `app/views/layouts/application.html.erb:8-9 (unconditional LogRocket init), :12-17 (identify with email); app/views/wallet_exports/show.html.erb:41,57 (key rendered into DOM); app/controllers/wallet_exports_controller.rb:36-51 (no layout override)`

**Attack scenario**

Every page on the default application layout loads cdn.logr-in.com/LogRocket.min.js and runs LogRocket.init('jodsqq/mcritchie-studio') with no env gate, plus LogRocket.identify(slug,{name,email}) on authenticated pages. WalletExportsController#show declares no layout, so it inherits this. On a legitimate self-custody export, show.html.erb renders the decrypted 64-byte secret key as visible DOM text in &lt;code&gt; blocks (base58 at :41, JSON byte-array at :57); x-show only toggles CSS, so the key is in the DOM from first paint. LogRocket records DOM/mutations and has NO dom/inputSanitizer/text-sanitization/blocklist config, so the plaintext key is transmitted to LogRocket servers and tied (via identify) to the victim's account+email. Any LogRocket org member, a compromised LogRocket account/API for that org, or anyone with replay-stream access recovers the full key and drains the wallet's USDC + entry tokens.

**Impact**

Plaintext private-key exfiltration to a third party on every wallet export, defeating the OPSEC-021 at-rest-encryption + log-redaction design. Full, irreversible drain of any managed wallet that passes through the export flow; identify() makes each captured key directly attributable to a named victim. (Merges KEY-3: the email in identify() is the correlation amplifier.)

**Fix (small)**

Override WalletExportsController#show to a minimal LogRocket-free layout (the existing modal_preview layout demonstrates the strip pattern). Belt-and-suspenders: wrap the key &lt;code&gt; blocks with data-private / LogRocket text-redaction, configure LogRocket with explicit dom textSanitizer/inputSanitizer + element blocklist, gate LogRocket to production only, drop email from identify() (use the opaque slug), exclude wallet/account/export routes from recording, and serve the reveal page with Cache-Control: no-store and Referrer-Policy: no-referrer.

---

### 🟠 #3 — settle_contest pays each winner to a fully unconstrained destination ATA — prize pool redirectable to any USDC account

- **Severity:** HIGH · **Status:** confirmed · **Component:** `turf-vault` · **Fix effort:** small
- **Location:** `programs/turf_vault/src/instructions/settle_contest.rs:128-173 (winner_ata = remaining[i*3+2], used verbatim at :164 with no owner/mint/ATA-derivation check)`

**Attack scenario**

Settlement remaining_accounts are triples [user_account, contest_entry, winner_ata]. The handler PDA-verifies the first two (user_account against [b'user', wallet] :134-141; contest_entry against [b'entry', contest_id, wallet, entry_num] :144-156) but NEVER validates the third — it is passed straight into the SPL Transfer as to: winner_ata_info.clone(). The only implicit constraint is the token program requiring winner_ata.mint == prize_pool.mint (USDC). Whoever assembles a settle TX (a malicious 2-of-3 insider, a compromised Alex-Bot server key + one human cosign, or a tamper of the remaining_accounts list before a human blind-signs in Phantom) keeps the real wallet/entry_num in the Settlement struct (so on-chain stats credit innocent winners) while substituting attacker-controlled USDC ATAs in slot 3, draining up to the full prize_pool. Contest then flips to Settled, making theft final. sweep_operator_revenue.rs DOES enforce treasury_ata.owner == treasury_authority — settle omits exactly that check, contradicting v0.16-spec §3.12 step 7 ('verify PDA seeds of all 3 triples').

**Impact**

Redirection of an entire contest's prize pool to an arbitrary account with on-chain stat counters left looking legitimate. Bounded by prize_pool per contest, unbounded across contests. Also turns any Rails bug in destination-ATA assembly into silent fund misrouting rather than a failed TX. High (not critical) because of the 2-of-3 settle precondition. (Merges TV-1 and FUND-1 — same root cause.)

**Fix (small)**

Bind the destination on-chain: require winner_ata == anchor_spl::associated_token::get_associated_token_address(&settlement.wallet, &payout_mint.key()), or unpack the destination TokenAccount and require owner == settlement.wallet AND mint == vault_state.payout_mint. This restores the spec's 'verify all 3 triples' intent and makes the cosigners' approval meaningful even under a tampered/blind-signed TX, matching the discipline already present in cancel_contest.rs and sweep_operator_revenue.rs.

---

### 🟠 #4 — Email change and first-password set require no re-auth for passwordless accounts — single hijacked session escalates to recovery-email + custodial-key takeover

- **Severity:** HIGH · **Status:** confirmed · **Component:** `turf-monster` · **Fix effort:** medium
- **Location:** `app/controllers/accounts_controller.rb:110-118 (update), :188-206 (change_password), :301-320 (initiate_wallet_export); app/controllers/wallet_exports_controller.rb:36-55 (key reveal); app/models/user.rb:214-216 (has_password?)`

**Attack scenario**

Most accounts are passwordless (magic-link/Google/wallet signups get a blank/throwaway password_digest and a server-held managed wallet). Given one hijacked session of such a user: (a) PATCH /account changing email — the re-auth gate is `if @user.has_password? && !authenticate(...)`, which short-circuits to false for passwordless users, so email changes and email_verified_at is nulled; (b) request+click an email_verification link (now attacker-owned email) to re-stamp email_verified_at; (c) POST /account/change_password — same has_password? short-circuit lets a passwordless user SET a first password with zero proof; (d) log in via /login with that password to stamp password_verified_at; (e) POST initiate_wallet_export now passes every gate (managed_wallet?, !self_custodied?, verified email, password_recently_verified?); (f) open the export token link — WalletExportsController#show reveals the full base58/CLI-JSON private key; (g) import and drain USDC + entry tokens on-chain, irreversibly. OPSEC-045 token binding does not break the chain: email change never rotates the token, and change_password rewrites the attacker's own cookie.

**Impact**

Single-session compromise of a passwordless managed-wallet account (the dominant user class) escalates to recovery-email takeover AND full theft of the server-held key controlling the user's USDC + entry tokens. The OPSEC-046 re-auth control and the wallet-export password gate are bypassed precisely for the most custodial users. High (not critical) because it presupposes an initial session hijack.

**Fix (medium)**

Do not treat 'no password' as 'no re-auth needed'. Require a second factor before email change, first-password set, and wallet export: an out-of-band confirmation link to the CURRENT email for email changes, and a fresh magic-link/email confirmation for change_password on a passwordless account. Stamp/clear password_verified_at appropriately and rotate session_token on email change (today only change_password rotates it).

---

### 🟠 #5 — set_contest_lock_time / set_contest_conclusion_time (1-of-3) can re-open a locked contest or clear its conclusion, enabling late results-known entries

- **Severity:** HIGH · **Status:** confirmed · **Component:** `turf-vault` · **Fix effort:** small
- **Location:** `programs/turf_vault/src/instructions/set_contest_lock_time.rs:38-64; set_contest_conclusion_time.rs:36-60; create_contest.rs:152 (conclusion_timestamp defaults to 0)`

**Attack scenario**

create_contest hardcodes conclusion_timestamp = 0; setting one is a separate optional 1-of-3 call Rails may never make. The lock is purely time-derived (enter_contest rejects only when Clock &gt;= lock_timestamp; Locked status is vestigial, so a time-locked contest is still status==Open). A holder of any single 1-of-3 signer (the always-online Alex Bot server key, which signs set_contest_lock_time alone with no cosign per vault.rb:788-808) can: (1) call set_contest_lock_time with new_lock_timestamp = now + 1 week on an already-locked contest — the only guard is `if conclusion_timestamp != 0 { require now &lt; conclusion }`, skipped by the default 0, and there is no monotonicity/already-locked check — re-opening entries; (2) even if a conclusion was set to harden it, set_contest_conclusion_time lets the same key push it into the future or clear it to 0 any time before it passes, re-arming the relock; (3) timestamps also accept past/negative values (STATE-4) so a contest can be created already-locked or have its lock permanently bricked. The attacker then enters known-winning lineups after real-world results and is graded/paid on settle.

**Impact**

A single 1-of-3 / server-key holder can resurrect a locked contest and accept post-result entries (classic late-entry fraud), or grief contests by locking out all entries. Defeats the entire purpose of the derived lock and the v0.18 conclusion 'finality' guarantee. Requires a vault-signer key (not external), but a routine-tier 1-of-3 key defeats a fund-fairness control. (Merges STATE-2, STATE-3, STATE-4 — same root cause: 1-of-3 mutable, non-monotonic, unbounded lock/conclusion setters.)

**Fix (small)**

Make the lock effectively one-way: reject set_contest_lock_time once the contest has locked (lock_timestamp != 0 && now &gt;= lock_timestamp) unless raised to 2-of-3. Make conclusion strictly monotonic-forward and irrevocable (reject 0/clearing and any earlier value once set), and require 2-of-3 to extend a lock or change a conclusion since these have direct fund-fairness impact. Validate timestamps: require new_ts == 0 || new_ts &gt; Clock::now, reject negatives, and require lock &lt; conclusion when both are set. Do not rely on an opt-in conclusion_timestamp that defaults to 0.

---

### 🟡 #6 — settle_contest has no lock/conclusion-time precondition — a contest can be graded while still open for entries and before it concludes

- **Severity:** MEDIUM · **Status:** confirmed · **Component:** `turf-vault` · **Fix effort:** small
- **Location:** `programs/turf_vault/src/instructions/settle_contest.rs:60-67 (status-only constraint), :90-216 (handler has no Clock/lock/conclusion check); enter_contest.rs:59,130-139; settle_contest.rs:216`

**Attack scenario**

settle_contest gates only on status == Open||Locked, with no Clock::get(), no lock_timestamp, and no conclusion_timestamp check. Because Locked is vestigial, every live contest is Open until settle flips it to Settled. With lock_timestamp == 0 (the create default unless Rails sets one), there is no on-chain lock at all, so entries are accepted up to the instant settle lands. There is thus a live race / no on-chain 'entries closed before grading' invariant: an entry can be slipped in immediately before grading, and the 2-of-3 settle authority can grade a contest before its lock/conclusion has passed. Note: payouts come from an operator-authored, 2-of-3-signed settlement vec built off-chain, so a brand-new on-chain entry not in that vec gets 0 (self-harm) — the on-chain gap alone does not extract funds.

**Impact**

Premature/early settlement and entry-after-effective-close races: the v0.18 conclusion-timestamp safety story is non-binding for the one operation it was meant to protect (final grading). Real harm is a defense-in-depth gap that lets a Rails bug or a partially-compromised signer grade a contest before it is over, or orphan a last-second entry (fee captured to op_rev, no payout). Bounded because the settlement set is operator-authored and multisig-gated. (Merges STATE-1 and STATE-5.)

**Fix (small)**

Gate settle on a passed lock/conclusion timestamp so there is a hard on-chain 'entries closed' boundary before grading: require!(contest.lock_timestamp != 0 && Clock::get()?.unix_timestamp &gt;= contest.lock_timestamp) (or conclusion_timestamp). Tie 'grading is allowed' to the same derived-time primitive the rest of v0.17/v0.18 relies on; consider snapshotting current_entries at lock and rejecting settle if entries changed after the lock boundary. This is the same fix that hardens rank 5.

---

### 🟡 #7 — Entry#confirm_onchain! has no entry-fee payment gate (unlike Entry#confirm!) — model fails open if a caller skips verification

- **Severity:** MEDIUM · **Status:** confirmed · **Component:** `turf-monster` · **Fix effort:** small
- **Location:** `app/models/entry.rb:167-203 (confirm_onchain!) vs :99-147 (confirm!, payment gate at :134)`

**Attack scenario**

Two model activation paths diverge. Entry#confirm! has the backstop `raise 'Entry payment required' if contest.entry_fee_cents.positive? && tx_signature.blank? && !comped`. Entry#confirm_onchain! — used by BOTH the verified path (confirm_onchain_entry) and the UNVERIFIED recovery path (recover_pending_entry, rank 1) — has no such gate; it does a bare update!(status: :active, ...) as long as it receives any non-nil tx_signature string and the open/lock/limit/sybil checks pass. Required kwargs only enforce presence, not non-blank or verified, so any junk string activates the entry. The only thing standing between a paid entry and activation is whether the caller verified the signature.

**Impact**

Removes the model-layer defense-in-depth: a single missing upstream verify (as in rank 1) turns into a free paid entry rather than being caught at the model. Makes the codebase one refactor away from re-introducing the rank-1 critical even after that controller is fixed.

**Fix (small)**

Make confirm_onchain! fail closed: require a verified signature (pass a verified flag from the controller, or re-verify inside the model against the server-derived entry PDA + signer), and add the same paid-contest payment assertion confirm! has. The model should never activate a paid entry on trust.

---

### 🟡 #8 — No uniqueness / replay guard on onchain_tx_signature anywhere (DB, model, or verifier) — one real signature can credit multiple DB rows

- **Severity:** MEDIUM · **Status:** confirmed · **Component:** `turf-monster` · **Fix effort:** small
- **Location:** `db/schema.rb:57,86,237 (no unique index on onchain_tx_signature / tx_signature); app/models/entry.rb (no validation); app/models/pending_transaction.rb:6-8; app/services/solana/tx_verifier.rb:30-73 (stateless)`

**Attack scenario**

TxVerifier proves a signature matches a tx shape but is stateless — it never records that a signature was consumed, and there is no unique DB index on onchain_tx_signature/tx_signature, nor a uniqueness validation. The semantically-verified paths (enter, confirm_onchain_entry, admin settle) are protected by on-chain PDA idempotency, but the recover_pending_entry path (rank 1) does not call TxVerifier at all, so the same arbitrary finalized signature can be stamped and recover-activated for up to max_entries_per_user distinct cart entries. Any future code path that credits state from a verified signature inherits the same replay hole.

**Impact**

Confirmation-by-signature replay. In combination with rank 1 it multiplies the free-entry forgery; independently it removes the single cheapest defense (a partial unique index) that would block one real signature from crediting multiple rows. Bounded by the per-user entry cap and largely dependent on the rank-1 verification gap. (One verifier flagged reachability as refuted; the correctness verdict and overall adjusted severity is medium — retained pending the rank-1 fix.)

**Fix (small)**

Add a partial unique index on entries.onchain_tx_signature (WHERE NOT NULL) and on pending_transactions.tx_signature, plus a uniqueness validation on Entry#onchain_tx_signature. Better: introduce a ConsumedSignature table (signature + purpose) written transactionally at confirm time, and have TxVerifier/callers reject an already-consumed signature — treat the signature as a single-use nonce, not a shape-checkable token.

---

### 🟠 #9 — mint_entry_token forges spendable free entries at 1-of-3 and has no on-chain source_ref idempotency despite docs claiming it

- **Severity:** HIGH · **Status:** confirmed · **Component:** `turf-vault` · **Fix effort:** medium
- **Location:** `programs/turf_vault/src/instructions/mint_entry_token.rs:26-82; lib.rs:227-234; state.rs:299-313`

**Attack scenario**

mint_entry_token is gated at only 1-of-3 (is_signer, not validate_multisig), while comparable value ops (settle/cancel/sweep) require 2-of-3. user_wallet is an UncheckedAccount, so a single signer (the hot Alex Bot server key on Heroku) can mint a token to any wallet. The PDA is keyed solely on [b'entry_token', user_wallet, sequence] with sequence caller-supplied; source_ref is stored verbatim with NO uniqueness check, so CLAUDE.md's 'idempotent per source_ref' claim is false on-chain — re-minting the same Stripe source_ref with a fresh sequence creates a brand-new spendable token. An attacker holding the Alex Bot key mints unlimited unconsumed tokens, each redeemable into any open contest via enter_contest_with_token (owner + !consumed are the only gates).

**Impact**

Free-entry forgery at scale gated by a single server-held key rather than a 2-of-3 quorum. The doc/code idempotency mismatch means the operator pipeline (TokenPurchaseJob retries on the same source_ref) is protected only by off-chain DB resume logic, not the chain. High because exploitation requires possession of a vault signer key (not external); one reachability verdict noted that post-key-compromise this is marginal versus that key's other powers, but the 1-of-3 privilege-tiering and false-idempotency defects are genuine and key-theft-independent.

**Fix (medium)**

(1) Enforce on-chain idempotency: derive the PDA from a hash of source_ref (seeds [b'entry_token', source_ref_hash]) so re-minting the same external reference collides on init and fails. (2) Raise mint_entry_token to 2-of-3, or split out a dedicated lower-trust minter key with a per-period cap, since it directly forges spendable value. (3) Correct the CLAUDE.md 'idempotent per source_ref' claim, which is currently false.

---

### 🟡 #10 — Chargeback/refund does not revoke already-minted on-chain entry tokens or gate settlement on frozen?; operator absorbs fraud loss

- **Severity:** MEDIUM · **Status:** confirmed · **Component:** `turf-monster` · **Fix effort:** medium
- **Location:** `app/controllers/webhooks/stripe_controller.rb:110-136 (handle_dispute/handle_refund); app/models/user.rb:218-230 (freeze_for_payment_risk!); app/models/contest.rb:176-229 (grade!) / :390-420 (settle_onchain!) — no frozen? check`

**Attack scenario**

Attacker buys a token pack via Stripe with a stolen/chargeback-prone card. TokenPurchaseJob mints the on-chain EntryTokenAccount PDAs immediately (irreversible). Attacker consumes tokens to enter contests and possibly wins a USDC payout to their ATA. Weeks later the chargeback fires; handle_dispute/handle_refund flags + freezes the PURCHASER, but the on-chain tokens are gone/consumed and any payout already landed; freeze only blocks future in-app actions. grade!/settle_onchain! build winners from rank/payout_cents alone with no user.frozen? / payment_risk_flag check, so a disputed user already ranked is still recorded for payout and included in the on-chain settlement. Tokens minted to / moved to an attacker-controlled wallet remain spendable on-chain regardless of the app freeze.

**Impact**

Operator (treasury) absorbs the cost of free entries / prize payouts obtained with fraudulent card payments. Bounded by pack price ($19/$49) plus prizes won, times fraud volume; meaningfully mitigated by the freeze for the common timeline but the irreversible immediate mint and missing settlement-time gate leave real leakage.

**Fix (medium)**

Add a settlement-time gate: skip/exclude entries where entry.user.frozen? || payment_risk_flag in grade!/settle_onchain!. Hold/delay the on-chain mint behind a short clearing window for first-time or risk-scored buyers. Add an operator clawback path (admin-signed token close / payout reversal) for disputed purchases; consider not auto-minting until the charge is captured and low-risk.

---

### 🟡 #11 — Production Rails.cache is per-process :memory_store, silently degrading magic-link single-use replay protection and rack-attack throttles

- **Severity:** MEDIUM · **Status:** confirmed · **Component:** `turf-monster` · **Fix effort:** trivial
- **Location:** `config/environments/production.rb:72; app/services/magic_link.rb:45-67,98-101; config/initializers/rack_attack.rb:19-104`

**Attack scenario**

Prod sets config.cache_store = :memory_store (per-process, lost on restart) even though Heroku Redis is attached and dev uses :redis_cache_store. MagicLink writes/deletes its single-use jti via Rails.cache, and enforce_single_use? returns true for :memory_store, so the code BELIEVES replay protection is on (the loud warn fallback never fires) — and the magic_link.rb/rack_attack.rb comments both falsely claim Redis/cross-process. Today Puma runs a single web process (no workers directive), so single-use and throttles actually work in-process. The replay/ATO becomes live the instant WEB_CONCURRENCY&gt;1 or web dynos scale &gt;1: a captured magic-link URL replayed against a process lacking the jti logs the bearer in within the 15-minute TTL. The same process-locality silently multiplies every rack-attack auth throttle by the worker/dyno count and resets them on restart.

**Impact**

Latent account-takeover and throttle-bypass that activates silently with a single benign-looking ops change (scaling web above one process), while the code falsely reports single-use as enforced. Medium: real, code-confirmed, defense-degrading, but conditional on a topology change rather than presently exploitable.

**Fix (trivial)**

Set config.cache_store = :redis_cache_store, { url: ENV['REDIS_URL'], ... } in production so jtis and rack-attack counters are cross-process and survive restarts. Point Rack::Attack.cache.store at the same Redis explicitly. Harden enforce_single_use? to require an explicitly cross-process store (raise/alert at boot if prod Rails.cache is a MemoryStore/NullStore) rather than merely 'not NullStore', and fix the misleading comments.

---

### 🔵 #12 — MoonPay webhook trusts attacker-controllable payload amount with no API re-fetch (latent value-forgery)

- **Severity:** LOW · **Status:** confirmed · **Component:** `turf-monster` · **Fix effort:** small
- **Location:** `app/controllers/webhooks/moonpay_controller.rb:49-92 (handle_transaction_completed); FIXME at :64-66`

**Attack scenario**

Given the MOONPAY_WEBHOOK_KEY (in prod the HMAC secret is the sole barrier; the fail-open branch is non-production-only and the initializer hard-raises at boot if MoonPay is enabled in prod without secrets), an attacker crafts a signed transaction_completed body with an arbitrary baseCurrencyAmount and POSTs it. The handler trusts the amount verbatim (line 71) and enqueues MoonpayDepositJob, which today only writes a TransactionLog audit row (no money moves; balances and the withdrawal cap read on-chain state directly). It becomes direct value forgery if the documented next step (server-side order registration / any TransactionLog-as-balance read or fund_user call) lands before the re-fetch FIXME is closed.

**Impact**

Currently audit-row pollution and inflated admin reporting totals only. Latent value-forgery / treasury-drain vector if the planned server-side order registration or any TransactionLog-as-balance read is added before the re-fetch FIXME is closed. Contrast the Stripe path which re-fetches and asserts amount via StripeCheckoutValidator.

**Fix (small)**

Close the FIXME before MoonPay is enabled in prod: re-fetch GET /v1/transactions/:id with the MoonPay API key and treat the API response (amount, currency, status, walletAddress) as authoritative; reject if the webhook payload diverges. Attribute via externalCustomerId, not walletAddress. Never let any job call fund_user based on webhook-supplied amounts.

---

### 🔵 #13 — merge_users! transfers credentials and pivots the session to the lower-id account without rotating session_token

- **Severity:** LOW · **Status:** uncertain · **Component:** `turf-monster` · **Fix effort:** small
- **Location:** `app/controllers/concerns/user_mergeable.rb:6-35; called from app/controllers/accounts_controller.rb:144 (link_solana)`

**Attack scenario**

merge_users! always keeps the LOWER id as survivor, blank-fills email/name/provider/uid and copies password_digest, repoints entries, destroys the absorbed user, then calls set_app_session(survivor) WITHOUT regenerate_session_token!. So a logged-in user who links a wallet bound to an OLDER account silently pivots the session into that older identity (the Google linking path deliberately refuses this exact merge and surfaces a CTA — the link_solana path does not). NOTE (uncertain/largely refuted by verification): reaching the merge requires a valid ed25519 signature with the wallet's private key over a User-ID/nonce/host-bound message, and web3_solana_address is uniquely indexed and only set via signature-gated paths, so this is a self-merge of two accounts the same party already controls — not a cross-user takeover. Absorbed-user sessions resolve to nil (logged out) after destroy.

**Impact**

Surprising session pivot and a missing session-token rotation (defense-in-depth gap), not the credential-takeover the finder originally framed. Needs manual confirmation of intent; the security exploit narrative was refuted but the behavioral wart is real.

**Fix (small)**

Call survivor.regenerate_session_token! before set_app_session so the merge invalidates other live sessions. Make the survivor deterministic by intent (keep current_user, not lowest id) or refuse the merge and surface a CTA like the Google path. Require re-auth before a destructive merge.

---

### 🔵 #14 — Wallet-export reveal page (#show) skips authentication and omits the Referrer-Policy / Cache-Control hardening that #consume sets

- **Severity:** LOW · **Status:** confirmed · **Component:** `turf-monster` · **Fix effort:** trivial
- **Location:** `app/controllers/wallet_exports_controller.rb:25-55 (show), :28 (skip_before_action :require_authentication), :94-107 (verify_export_token); accounts_controller.rb:301-320 (initiate)`

**Attack scenario**

GET /account/wallet/export/:token renders the managed wallet's 64-byte secret key and skips require_authentication, so possession of the signed 30-min token alone authorizes the reveal. Within the TTL, inbox access (compromised email, forwarding rule, shared device) opens the key. The page sets no Referrer-Policy: no-referrer (unlike MagicLinksController#consume) and no Cache-Control: no-store. The cross-origin Referer-leak vector is largely mitigated by modern browser strict-origin-when-cross-origin defaults, so the realistic risk is inbox access plus the LogRocket DOM capture (rank 2). Strong Stage-1 reauth (recent password + verified email + 30-min TTL + initiated_at binding) bounds it.

**Impact**

Key compromise of a managed wallet if the single-use 30-min token leaks. Bounded by the strong Stage-1 reauth and short TTL, hence low; the missing Referrer-Policy/Cache-Control on the secret-rendering page is a concrete, cheap hardening gap. Closely related to rank 2 (same page).

**Fix (trivial)**

Set Referrer-Policy: no-referrer and Cache-Control: no-store in #show. Reveal the secret only after a second in-page POST so the GET (which may sit in browser history/Referer) never contains the key. Confirm the export token only ever travels in the mailer link. (Fix rank 2's LogRocket layout issue on the same page.)

---

### 🔵 #15 — Email uniqueness is case-sensitive in DB/model while auth lookups normalize to lowercase — account-confusion / dual-identity surface

- **Severity:** LOW · **Status:** confirmed · **Component:** `turf-monster` · **Fix effort:** small
- **Location:** `db/schema.rb:458 (unique index on raw email, no lower()); app/models/user.rb:12 (case-sensitive uniqueness); app/controllers/accounts_controller.rb:336 (account_params, no downcase)`

**Attack scenario**

The users.email unique index is on the raw column and the model validation is case-sensitive by default, while MagicLink/Google lookups force lowercase and password login uses params[:email] verbatim. So rows victim@x.com and Victim@X.com can coexist; the from_omniauth collision check silently creates a second parallel account for a mixed-case stored row, and which account a credential resolves to depends on casing. The username column already uses the lower() pattern (schema.rb:456) — email was not given the same treatment.

**Impact**

Inconsistent email identity across auth paths; dual/confused accounts that complicate ownership, support recovery, and the merge/link logic, and bypass the 'this email already has an account' check. No takeover or fund/key loss; weakens the 'one email = one identity' invariant rank 4/13 lean on.

**Fix (small)**

Normalize email to lowercase on write (before_validation in User), switch to citext or add a unique index on lower(email) mirroring the username pattern, and downcase in account_params so all auth paths agree on the canonical identity.

---

### 🔵 #16 — CSP allows 'unsafe-inline' + 'unsafe-eval' on script-src — any future HTML-injection sink becomes executable XSS on the fund-handling origin

- **Severity:** LOW · **Status:** confirmed · **Component:** `turf-monster` · **Fix effort:** medium
- **Location:** `config/initializers/content_security_policy.rb:23`

**Attack scenario**

script-src is :self, :https, :unsafe_inline, :unsafe_eval (the file's own comment defers nonces to a follow-up). Current user-content sinks are individually escaped/safe today, so this is defense-lost, not a live XSS. But any single future escaping mistake (a new raw user.bio, a mishandled JSON script block, etc.) on the payments/wallet origin becomes full session-context theft / wallet-action forgery instead of a contained reflected string.

**Impact**

No standalone exploit today; removes the safety net that would neutralize a single escaping bug on a fund-handling origin. Reachability depends on a co-occurring injection sink.

**Fix (medium)**

Move to Rails 7 nonce-based CSP (policy.script_src :self, :https + content_security_policy_nonce_generator) and drop :unsafe_inline/:unsafe_eval from script-src; nonce-tag the inline Alpine factories/x-data. At minimum drop :unsafe_eval (Alpine 3 CSP build does not require eval) to shrink the gadget surface.

---

### 🔵 #17 — Sidekiq Web admin gate checks role but skips the OPSEC-045 session-token revocation check

- **Severity:** LOW · **Status:** confirmed · **Component:** `turf-monster` · **Fix effort:** trivial
- **Location:** `config/routes.rb:6-24 (SidekiqAdminMiddleware#call)`

**Attack scenario**

Sidekiq::Web is mounted as a standalone Rack app whose only guard (SidekiqAdminMiddleware#call) loads the user from the session and gates solely on user&.admin? — it never compares session['session_token'] to user.session_token. So when an admin rotates their password (which regenerate_session_token! is designed to use for revoking other sessions via ApplicationController#verify_session_token), a previously-stolen admin cookie still reaches /admin/jobs, exposing job arguments (user ids, wallet addresses, stripe session ids) and retry/kill/enqueue.

**Impact**

Post-password-rotation session revocation does not extend to the Sidekiq dashboard; a stolen admin session survives there until the cookie expires. Heavy preconditions (already-stolen signed/encrypted admin cookie + subsequent password rotation), so low; impact bounded to dashboard read + job control.

**Fix (trivial)**

In SidekiqAdminMiddleware#call, after loading user, also require session['session_token'] && session['session_token'] == user.session_token before @app.call(env); otherwise return the 404 body. This mirrors OPSEC-045 so dashboard access follows the same revocation lifecycle as the app.

---

### ⚪ #18 — email_verification tokens have no single-use/replay protection (24h replayable signed token)

- **Severity:** INFO · **Status:** confirmed · **Component:** `turf-monster` · **Fix effort:** small
- **Location:** `app/controllers/email_verifications_controller.rb:36-56; routes.rb:115-116`

**Attack scenario**

The email-verification token is a bare message_verifier blob bound to (user_id, email, return_to) with a 24h TTL and no jti / consumption record. Anyone who observes the verify URL once can replay it within 24h. Standalone impact is near-nil: the email_verified_at write is idempotent (guarded by if blank?), the action mints no session (no log_in/sign_in present), and it only follows a signed sanitized local redirect. It is a knowingly-accepted design tradeoff but is a load-bearing step in the rank-4 takeover chain (re-verifying the swapped-in email).

**Impact**

Long-lived (24h) replayable email-verification credential. Info-level in isolation (idempotent flag stamp, no session), but it removes a friction point in the rank-4 chain and is below the bar the app set for its own magic links.

**Fix (small)**

Give email_verification tokens the same jti single-use treatment as MagicLink (backed by the Redis store from rank 11). Shorten TTL well below 24h and bind to a token version so a verified email burns the token.

---

### 🔵 #19 — Operator revenue commingled in one per-mint ATA; per-contest entry_fees tallies are advisory and can drift from real balances

- **Severity:** LOW · **Status:** confirmed · **Component:** `turf-vault` · **Fix effort:** medium
- **Location:** `programs/turf_vault/src/instructions/enter_contest.rs:91-99,173-175; sweep_operator_revenue.rs:41-110; close_contest.rs:60-92`

**Attack scenario**

All entry fees for a mint across all contests flow into a single [b'op_rev', mint] PDA; close_contest (1-of-3) sweeps Settled-contest prize-pool dust into that same op_rev ATA; sweep_operator_revenue drains by live balance with no reference to per-contest entry_fees, and there is no global swept-revenue counter or on-chain invariant linking the commingled balance to the per-contest counters. prize_pool is never decremented on settle. So per-contest entry_fees[idx] can show already-swept revenue, and the numbers Rails uses for accounting are advisory only.

**Impact**

No theft of user principal (settle caps payouts at prize_pool, cancel refunds full balance, close moves only operator-margin dust from already-Settled contests). Pure accounting-trust limitation plus a minor threat-model note that a single 1-of-3 close can route Settled-contest residual into sweepable revenue (bounded because reaching Settled already required a 2-of-3 settle).

**Fix (medium)**

Document and reconcile: have sweep/close emit the per-contest delta, track a global swept-revenue counter on VaultState, and make the 1-of-3 authority on a fund-moving close explicit in the threat model. Confirm Cancelled contests cannot reach close with residual (cancel zeroes the pool first).

---

### 🔵 #20 — Jurisdiction (geo) gating trusts request.remote_ip and is the only server-side enforcement of restricted-state blocking

- **Severity:** LOW · **Status:** uncertain · **Component:** `turf-monster` · **Fix effort:** medium
- **Location:** `app/controllers/application_controller.rb:147-171 (detect_geo_state/geo_blocked?); app/models/geo_setting.rb:15`

**Attack scenario**

detect_geo_state resolves request.remote_ip via Geocoder and caches geo_state in the session for 24h; geo_blocked? is the sole server gate on entry/withdraw. A user in a banned state connects through a VPN/residential proxy in a permitted state and the gate passes. XFF forgery is blocked by Rails' default RemoteIp ip_spoofing_check (no trusted_proxies override exists) and the admin-only geo_override cannot be set by users, so VPN is the only realistic bypass — the inherent limitation of any IP geofencing, not a code defect.

**Impact**

Regulatory/AML exposure (real-money entries from banned states), not fund/key loss and no on-chain consequence. Uncertain: the underlying factual claim is accurate but the code is doing what it intends; this is a compliance-policy decision, not a bug.

**Fix (medium)**

Treat client-derived geo as advisory; layer KYC / payment-rail geo signals (Stripe Radar / card BIN country, MoonPay KYC country) for the actual compliance gate, confirm the proxy chain sets trusted_proxies, and document VPN bypass as accepted risk if that is the decision.

---

### 🔵 #21 — tokens/dev_mint route drawn in production (free on-chain token mint endpoint), relies solely on controller triple-gate

- **Severity:** LOW · **Status:** confirmed · **Component:** `turf-monster` · **Fix effort:** trivial
- **Location:** `config/routes.rb:233 (outside the unless Rails.env.production? block); app/controllers/tokens_controller.rb:127-147,164-172`

**Attack scenario**

dev_mint mints free on-chain entry tokens. Its route is registered in production, unlike sibling dev routes that are wrapped in unless Rails.env.production?. The controller gate ANDs current_user.admin? && Solana::Config.devnet? && !Rails.env.production?, so on a correctly-configured prod dyno the !Rails.env.production? clause makes it unreachable — no live bypass. Exploitation needs a compound misconfiguration (a mainnet-pointed dyno running RAILS_ENV non-production + a stolen admin session + SOLANA_NETWORK=devnet).

**Impact**

No reachable exploit on a correctly-configured prod dyno. Hardening gap only: leaks a free-mint endpoint into the public route table and relies entirely on env hygiene + admin-session integrity instead of route-level removal. The controller's own comment recommends removing it.

**Fix (trivial)**

Move the tokens/dev_mint route inside the unless Rails.env.production? block exactly like the other dev-only routes, so it is never drawn in production regardless of admin/session/network state.

---

### 🔵 #22 — Borsh decoder silently truncates / type-confuses on short or crafted account data; out-of-range offset raises uncatchable-by-contract NoMethodError

- **Severity:** LOW · **Status:** confirmed · **Component:** `solana-studio` · **Fix effort:** small
- **Location:** `lib/solana/borsh.rb:63-91 (decode_u8/u16/u32/u64, decode_pubkey, decode_string)`

**Attack scenario**

Precondition: attacker controls the bytes a decoder sees — realistically a malicious or compromised RPC endpoint (the Client enforces https + VERIFY_PEER + TLS1.2, so a network MITM cannot inject; the attacker must compromise the trusted provider/credentials). decode_u64 on &lt;8 bytes returns nil silently while advancing offset; decode_string/decode_pubkey return undersized slices but advance offset by the DECLARED length, so subsequent fields read at the wrong position; decode_u32/u8 past EOF raise a raw NoMethodError that consumers rescuing only Solana::Borsh::DecodedFieldTooLarge will not catch. Downstream consumers (sync_balance, decode_entry_token, decode_season) surface these as 'verified' values. (Merges BORSH-1 and BORSH-2 — same root cause: decoders not fail-closed.)

**Impact**

No fund drain or auth bypass (the on-chain program is authoritative; the token-path PDA comes from the RPC envelope, not the decoded body). Realistic worst case is mis-rendered 'verified' balances/eligibility and an unrescued 500 on a maliciously short account — robustness/integrity, not a vuln with on-chain consequence; bounded by the high-privilege RPC-compromise precondition.

**Fix (small)**

Make all decode_* helpers fail-closed: assert byteslice(offset, N)&.bytesize == N (and string/pubkey slice equals requested length) before advancing offset, treat any nil unpack1 as a decode error, and raise a single dedicated Solana::Borsh::DecodeError on any short read so consumers have one catchable contract. Add a per-layout expected-total-length assertion. One-file fix that resolves both the silent-nil and uncatchable-exception cases.

---

### 🔵 #23 — AuthVerifier nonce-expiry check is silently skipped when nonce_at is nil (fail-open API)

- **Severity:** LOW · **Status:** uncertain · **Component:** `solana-studio` · **Fix effort:** trivial
- **Location:** `lib/solana/auth_verifier.rb:55-57`

**Attack scenario**

verify! documents and advertises a 300s nonce TTL, but the expiry branch is `if nonce_at && (now - nonce_at) &gt; max_age` — a nil nonce_at skips the staleness check entirely (the method hard-rejects a nil stored_nonce but not a nil nonce_at), so the nonce never expires. UNCERTAIN/largely refuted by verification: the sole caller pulls stored_nonce and nonce_at from the same Rails session, which assigns both atomically into one signed/encrypted cookie, so a nil nonce_at can never accompany a live stored_nonce in the current codebase. The replay window only opens for a future/third-party caller that supplies a nonce without a timestamp.

**Impact**

Not exploitable today (the bad input is unreachable; real replay protection rests on delete-before-verify + host binding + a fresh random nonce). Genuine fail-open API-design wart in a pure library: a future or external caller that forgets nonce_at silently loses the documented staleness layer. Needs manual confirmation that no consumer ever passes a nil nonce_at.

**Fix (trivial)**

Fail closed: raise VerificationError, 'No nonce timestamp provided' if nonce_at.nil? (or make nonce_at a required, non-optional kwarg), treating it the same as the already-hard-rejected nil stored_nonce.

---

### 🔵 #24 — stamp_entry_signature authorizes via nil==nil for a null-initiator PendingTransaction (latent IDOR)

- **Severity:** LOW · **Status:** confirmed · **Component:** `turf-monster` · **Fix effort:** trivial
- **Location:** `app/controllers/contests_controller.rb:597-608 (stamp_entry_signature), cross-ref :620-624 (recover_pending_entry)`

**Attack scenario**

The guard is `unless ptx.initiator_address == current_user&.web3_solana_address`. For a web2/managed user, web3_solana_address is nil; if a PendingTransaction ever had a nil initiator_address, the comparison is nil == nil =&gt; true, authorizing the request and force-updating the PT to status:submitted with an attacker-chosen tx_signature. NOT reachable today: the only PT creators set non-nil initiators (admin pubkey for settle PTs; gated web3 address for entry PTs). It becomes live the moment any future code path creates a PT without setting initiator_address. recover_pending_entry additionally requires entry.is_a?(Entry); stamp_entry_signature has no such target-type guard.

**Impact**

Latent broken-access-control / PT tampering. If a nil-initiator PT is ever introduced, any logged-in web2 user could overwrite its tx_signature and flip it to submitted, corrupting treasury/entry bookkeeping. No fund movement on its own; low because no live path exists.

**Fix (trivial)**

Make the authorization explicit and null-safe: return head :forbidden if current_user.web3_solana_address.blank? || ptx.initiator_address.blank? before the comparison, OR scope to the user's own entries (ptx.target.is_a?(Entry) && ptx.target.user_id == current_user.id) as recover_pending_entry does. Apply identically at both :603 and :624.

---

### ⚪ #25 — settle_contest remaining-account user/entry PDAs not checked for program ownership before deserialize/mutation

- **Severity:** INFO · **Status:** uncertain · **Component:** `turf-vault` · **Fix effort:** trivial
- **Location:** `programs/turf_vault/src/instructions/settle_contest.rs:129-213`

**Attack scenario**

settle passes user_account and contest_entry as raw AccountInfo and mutates via try_borrow_mut_data + try_serialize, verifying the address against find_program_address but with no explicit require!(info.owner == ctx.program_id). The discriminator check in try_deserialize plus the PDA-address pin are the only implicit guards. UNCERTAIN/effectively non-exploitable: the instruction is reachable only by the trusted 2-of-3 multisig, the PDA address is pinned, and the Solana runtime only persists writes to program-owned accounts — so a write-back to a forged non-program-owned account cannot commit.

**Impact**

No reproducible impact (trusted caller, address-pinned, runtime ownership enforcement on writes). A standard-Anchor remaining-account hygiene gap worth closing as defense-in-depth, but no fund/correctness consequence.

**Fix (trivial)**

Add explicit require!(user_account_info.owner == ctx.program_id, VaultError::Unauthorized) and the same for entry_account_info before deserializing, matching standard Anchor remaining-account hygiene.

---

### ⚪ #26 — entry_token is not PDA-seed-bound in enter_contest_with_token — validated only by a self-asserted owner field

- **Severity:** INFO · **Status:** uncertain · **Component:** `turf-vault` · **Fix effort:** small
- **Location:** `programs/turf_vault/src/instructions/enter_contest_with_token.rs:69-76`

**Attack scenario**

entry_token is the only account in the struct with no seeds constraint — accepted purely via Anchor program-ownership + discriminator, entry_token.owner == user.key(), and !entry_token.consumed. The PDA seeds [b'entry_token', owner, sequence] are never re-derived. UNCERTAIN/effectively non-exploitable today: such an account can only be created by the vault-signer-gated mint_entry_token, so an external attacker cannot forge one; the existing guards fully constrain behavior. It would become exploitable only if a future re-init or account-confusion bug let a user influence the owner field.

**Impact**

Defense-in-depth gap: the consumed-token guarantee rests on a mutable on-chain field instead of cryptographic PDA derivation, with no second line of defense if the owner field is ever attacker-influenced. No live exploit; the only benign behavioral nuance is that a user may consume any of their own fungible tokens rather than the exact sequence Rails chose.

**Fix (small)**

PDA-seed-bind the entry_token: add an instruction arg sequence: u64 and constrain seeds = [b'entry_token', user.key().as_ref(), &sequence.to_le_bytes()], bump = entry_token.bump, removing reliance on the mutable owner field as the sole gate.

---

### ⚪ #27 — admin/usdc_balance is the one AdminController action excluded from require_admin (reachable by any logged-in user, but self-only)

- **Severity:** INFO · **Status:** confirmed · **Component:** `turf-monster` · **Fix effort:** trivial
- **Location:** `app/controllers/admin_controller.rb:2 (before_action :require_admin, except: [:usdc_balance]), :224-235; routes.rb:317`

**Attack scenario**

Any authenticated non-admin GETs /admin/usdc_balance; require_admin is skipped. The action returns only the CALLER's own on-chain USDC balance (fetch_user_usdc is hardcoded to current_user.solana_address; cache key is namespaced by current_user.id; anonymous requests get 401). No params accept a target user id, so there is no cross-user exposure or privilege escalation today.

**Impact**

None beyond surface-area confusion: an /admin/-prefixed route is non-admin-reachable, easy to misread during future edits and could become a real leak if someone later adds a params[:user_id] lookup.

**Fix (trivial)**

Move this to a non-admin path (e.g. /wallet/usdc_balance) so it does not signal as an operator endpoint, or drop the except: and reuse AccountsController#session_refresh. If kept, comment that it is intentionally self-only and must never accept a user identifier param.

---

### ⚪ #28 — Mainnet build hard-codes declare_id! to the System Program ID placeholder

- **Severity:** INFO · **Status:** confirmed · **Component:** `turf-vault` · **Fix effort:** trivial
- **Location:** `programs/turf_vault/src/lib.rs:46-47; also Anchor.toml [programs.mainnet] and scripts/squad.json`

**Attack scenario**

On a --features mainnet build, declare_id!('11111111111111111111111111111111') resolves the program ID to the System Program. The mainnet branch is gated behind a manual one-shot launch step; default/devnet/prod builds bind the real ID. Deploying at the System Program address is impossible and Anchor's build-time program-id self-check aborts on mismatch, so accidental shipment would brick the deploy rather than silently misbehave.

**Impact**

Process/hardening only: a bricked mainnet deploy at most if the launch checklist is skipped. Not attacker-triggerable and unreachable in any current build.

**Fix (trivial)**

Replace with the real mainnet program keypair pubkey as the final launch step, and add a CI/compile_error! guard that fails any --features mainnet build whose declare_id! still equals 1111...1111.

---

### 🔵 #29 — mint_entry_token idempotency keyed on caller-supplied sequence, not source_ref — operator-side double-mint of free entries

- **Severity:** LOW · **Status:** confirmed · **Component:** `turf-vault` · **Fix effort:** small
- **Location:** `programs/turf_vault/src/instructions/mint_entry_token.rs:44-82 (PDA seeds [b'entry_token', user_wallet, sequence]; source_ref stored but never used for uniqueness)`

**Attack scenario**

The PDA and Anchor init uniqueness key on (user_wallet, sequence); source_ref is a stored field never used for uniqueness. Two mints with the same Stripe source_ref but different sequence both succeed, each producing a redeemable EntryTokenAccount. If Rails recomputes sequence for an already-fulfilled purchase (a retried/duplicated TokenPurchaseJob or webhook replay racing on per-wallet current_count), the same paid purchase yields two free-entry vouchers. Not externally reachable (requires the 1-of-3 admin key). Closely related to rank 9 (same false 'idempotent per source_ref' claim).

**Impact**

Operator-side double-issuance of free entries if the off-chain sequence allocation is not strictly idempotent. No fund theft; value forgery of paid entries, bounded by admin-key trust + off-chain sequence discipline since there is no on-chain idempotency backstop.

**Fix (small)**

Derive the PDA from a hash of source_ref (so a given external reference mints at most one token), or document that idempotency is Rails' responsibility via a strictly monotonic per-wallet sequence plus a DB unique index on source_ref. Update the misleading 'idempotent per source_ref' comments. (Same remediation cluster as rank 9.)

---

## Appendix A — Refuted findings (checked under verification, dismissed)

These were raised by a finder but did not survive adversarial verification — a guard exists, the path is unreachable, or the finder misread the design. Recorded so they are not re-investigated.

- **KEY-2: Managed-wallet contest entry server-signs even after the user has self-custodied** — The finder read only contests_controller.rb:424-479 and missed the unconditional self-custody guard at the top of #enter (lines 356-367): `if current_user.self_custodied? return render ... status: :unprocessable_entity`. This early return short-circuits the entire action before either server-signing branch (line 424 enter_contest_with_token, line 454 enter_contest), so a self-custodied user gets HTTP 422 and the server never auto-signs with the custodial key. The retained-ciphertext observation is accurate but moot because the signing path is unreachable for self-custodied users. The alternate on-chain actions (prepare_entry, confirm_onchain_entry) are the correct Phantom co-sign path, not a bypass.
- **TXVERIFY-4: TxVerifier does not verify the transferred amount/destination (relies on the program to enforce the fee)** — The finding's load-bearing claim — that the verifier's docstring CLAIMS to assert 'moved the right amount to the right account' while the code does not — is fabricated; the actual docstring (tx_verifier.rb:1-26) only claims to verify program-touch, discriminator, signer-present, and PDA-present+writable, which is exactly what the code does. The verifier also rejects any on-chain-failed tx, and the deployed enter_contest.rs requires entry_fee&gt;0 and performs a PDA-seed-bound token::transfer(entry_fee) before initializing the entry, so a fee-free tx cannot both succeed on-chain and satisfy the verifier. confirm_onchain! credits no Rails-side balance. The proposed IDL-hash safety net is also misdescribed (the discriminator is name-derived, not IDL-derived). Legitimate residual is only a defense-in-depth documentation note, not a code-vs-docs contradiction.
- **POR-1: Proof-of-reserves / landing-page meta render server JSON/strings into script/attribute context with html_safe (stored XSS)** — Both claimed sinks are protected by escaping the finder missed. The premise that Rails to_json leaves &lt;/script&gt; intact is false for this codebase: ActiveSupport's escape_html_entities_in_json defaults to true (and is not overridden), so &lt;/script&gt; is unicode-escaped in the proof-of-reserves &lt;script type='application/json'&gt; block — the script element cannot be terminated. The landing og:title/og:description/h1/badge fields are plain &lt;%= %&gt; with default ERB HTML-escaping (no raw/html_safe on user/admin strings), so a quote/angle-bracket cannot break out of the attribute. Neither sink is injectable; the json_escape recommendation is redundant.
- **FUND-4 / ETK-1 (merged): Token-funded entry is unbound to contest fee/tier — a cheap token enters any contest (value forgery)** — The structural code observation (EntryTokenAccount has no value/tier field; enter_contest_with_token does no fee matching) is accurate, but the value-forgery exploit does not hold. (1) Both mint_entry_token and enter_contest_with_token require a vault signer as payer (is_signer constraint), so no unprivileged user can mint or redeem against an arbitrary contest without the operator co-signing — and the Rails server chooses the target contest, not the attacker. (2) All turf-monster contest tiers share a uniform $19 entry fee (tiers differ only in seats/prize structure), so a $19 token entering any tier is the intended price, not a mismatch. (3) Prize pool is creator-funded and immutable, and settle_contest caps total_payouts &lt;= prize_pool with payouts driven by an operator-authored 2-of-3-signed settlement vec — holding a ContestEntry PDA disburses zero USDC. The 'compete for / win the full prize pool for free' step requires operator grading, not the on-chain flaw. Real residual is a defense-in-depth note: bind tokens to a tier/value at mint time so the gap cannot become exploitable if per-tier prices ever diverge or a signer key is compromised.
- **STATE-6: Solana Clock is the sole unauthenticated time source for the lock/conclusion gates** — The code matches the description, but it is not a defect. The Clock sysvar is not caller-settable; an attacker cannot move it (the finding itself concedes 'not attacker-controllable'). The only effect is benign validator clock skew (seconds) deciding marginal at-the-boundary entries — an inherent, documented property of any oracle-free on-chain time-lock, explicitly chosen in v0.17. The lock comparison is logically correct (no off-by-one/overflow). The only actionable item is operational (set lock_timestamp a conservative margin before kickoff), already noted in the doc comments. No exploit exists.
- **AUTH-2 (crypto): verify! returns the attacker-supplied pubkey string verbatim without canonicalization (base58 aliasing)** — Aliasing is mathematically impossible once verify!'s 32-byte length guard passes (a precondition for returning the value). base58 decode is positional so the numeric value is unique; the only aliasing dimension is leading '1' characters (zero bytes), whose count is pinned to the fixed value's leading zero bytes — so canonical re-encoding always equals the input for any string decoding to exactly 32 bytes. Empirically the returned pubkey equaled encode_base58(pub_bytes) in 1000/1000 successful verifications (the proposed fix is a no-op), and the 33-byte '1'+addr alias is rejected by the length guard. The cross-consumer scenario references controller files in a separate repo. Returning encode_base58(pub_bytes) would be harmless clarity but closes no actual gap.
- **KEYPAIR-1: normalize/encode_pubkey treat any 32-byte string as raw bytes and skip base58 decoding (mis-routing)** — The branch logic exists, but the mis-routing input is mathematically nonexistent: base58 is all-ASCII (bytesize == char-length) and real 32-byte Solana pubkeys encode to 43 or 44 characters (200k random keys produced only 43/44, never 32). A 32-character base58 string decodes to at most ~24 bytes and never represents a valid 32-byte address, so the bytesize==32 fast path only ever fires for genuine raw 32-byte keys; real addresses always hit the decode branch. encode_pubkey hard-guards at borsh.rb:37 and no lib caller passes an ambiguous 32-char string. Length-based rather than type-based disambiguation is a legitimate code smell (a typed Pubkey wrapper would be reasonable hardening) but there is no concrete vulnerability.
- **TXVERIFY-2 reachability sub-verdict (the finding itself is RETAINED at medium)** — NOTE: TXVERIFY-2 is NOT dropped — it appears in the main list at rank 8 (medium, confirmed on the correctness lens). One verifier's reachability-lens sub-verdict argued the missing unique index is hardening-only because the verified paths bind the signature to a server-derived PDA protected by on-chain idempotency. That sub-verdict was contained in a corrupted/garbled verdict object with duplicated sacrificial fields and is recorded here only for completeness; the authoritative correctness verdict confirms a real replay surface via recover_pending_entry, so the finding remains in scope.

---

## Appendix B — Surface NOT covered (recommended follow-up before mainnet)

The completeness critic flagged these attack classes as under-weighted by this pass. Recommend a dedicated follow-up audit before flipping the SOL gate to mainnet.

- **Dependency / supply-chain provenance (Gemfile.lock, IDL, package-lock, node_modules)** — No dimension covered the trust chain on third-party code or the on-chain&lt;-&gt;IDL binding. (1) IDL provenance is only self-referential: Solana::Config.verify_idl! and bin/rails solana:health (lib/tasks/solana.rake:431) compare the LOCALLY-committed config/turf_vault.idl.json against an operator-set EXPECTED_IDL_HASH — both operator-controlled. Nothing verifies the committed IDL/hash corresponds to the bytecode actually deployed on-chain, and the project's own docs note Squad upgrades do NOT update the on-chain IDL account, so there is no source-of-truth to cross-check against. A BYPASS_IDL_CHECK=true escape hatch (config.rb:97) silently disables even the local check with only a log line. (2) studio-engine is pinned `~&gt; 0.4.0` (Gemfile:79) but Gemfile.lock resolves 0.4.11 — a wide minor-version float on a gem that ships the actual auth/session controllers. (3) turf-monster's package-lock.json has only 5 integrity hashes and node_modules vendors tweetnacl (client-side Ed25519 used in the wallet path) and Playwright; the vault's yarn.lock/Cargo.lock (Anchor 0.32.1, anchor-spl, web3.js, @sqds/multisig) were never scanned for known-vuln/yanked versions or transitive-dependency confusion. For an app moving real USDC, a poisoned IDL or a compromised transitive dep in the signing path is a direct fund-loss vector.  
  _Follow-up:_ Add a dedicated supply-chain pass: (a) `bundle audit`/`bundler-audit` + `cargo audit` + `npm audit` against all three lockfiles with results triaged; (b) tighten the studio-engine pin to `~&gt; 0.4.11` and audit the engine repo's auth controllers as their own dimension (see next gap); (c) replace operator-set EXPECTED_IDL_HASH with a build-from-verified-source flow and document that the on-chain bytecode hash (`solana program dump` + sha256, or a verified-build attestation) is the real anchor, not a committed JSON; (d) gate BYPASS_IDL_CHECK behind a time-boxed, alerting mechanism.
- **studio-engine shared auth controllers (out-of-scope auth machinery)** — The auth-session dimension audited turf-monster's OVERRIDES, but the actual login/password/magic-link/OAuth-callback logic lives in the studio-engine gem (studio-engine/app/controllers/sessions_controller.rb, registrations_controller.rb, omniauth_callbacks_controller.rb) — a separate repo that was never an audit dimension. sessions_controller#create still runs `user&.authenticate(params[:password])` and the magic-link/session_token issuance + the OPSEC-045 session-token revocation primitive the web-layer finding referenced all originate there. Several turf-monster confirmed findings (no-reauth email/password change, session_token rotation on merge, Sidekiq gate skipping the revocation check) are symptoms whose root logic sits in unaudited engine code shared across multiple production apps (turf-monster, mcritchie-studio, tax-studio).  
  _Follow-up:_ Run the auth-session dimension against the studio-engine repo itself: session_token issuance/rotation/revocation lifecycle, magic-link single-use enforcement, password reset, and the OmniAuth merge/identity-linking flow — then re-evaluate the turf-monster findings in light of where the fix has to land (engine vs app) to avoid fixing one consumer while leaving the shared gem vulnerable.
- **Operational security of the single hot admin/deploy key (SOLANA_ADMIN_KEY blast radius)** — key-custody focused on USER managed-wallet keys and LogRocket leakage, but the highest-value key — Alex Bot (SOLANA_ADMIN_KEYPAIR / SOLANA_ADMIN_KEY, signer #1, config.rb:22) — lives as a plaintext base58/JSON on the Heroku web dyno and is the 1-of-3 routine signer for create_contest, the enter_contest payer, set_contest_lock_time, set_contest_conclusion_time, AND mint_entry_token. The confirmed vault findings 'leaked vault signer (1-of-3) mints unlimited free entries' and 'set_lock_time can re-open a locked contest' are downstream of THIS key's compromise, yet its custody, rotation story, and blast radius never got a dedicated pass. The same key is documented (vault CLAUDE.md) as the upgrade buffer-payer and is pulled from 1Password into env for squad-upgrade.js. A single Heroku config-var exfiltration (the memory notes already flag that ~/.zprofile is readable to agents and HEROKU_API_KEY is reachable) yields all 1-of-3 routine powers plus the ability to grief locks and mint free entries.  
  _Follow-up:_ Dedicated key-custody-ops pass: enumerate every key (Alex Bot server key, MANAGED_WALLET_ENCRYPTION_KEY, Mason/Alex Squad keys, Heroku API token) — where each lives, who/what can read it, rotation procedure, and the exact on-chain capability set of each. Specifically scope: what becomes possible if the Heroku dyno's SOLANA_ADMIN_KEY leaks, and which of the confirmed 1-of-3 findings should be re-rated CRITICAL once that realistic compromise path is assumed. Recommend moving routine-signer ops behind a separate constrained signer or HSM/turnkey rather than a plaintext env var.
- **Squads multisig upgrade-authority compromise & mainnet placeholder enforcement** — vault-authority found the System-Program placeholder declare_id but the multisig upgrade path itself was not threat-modeled. scripts/squad.json ships mainnet programId/multisigPda/vaultPda as all-1s placeholders with a comment that squad-upgrade.js 'must refuse any --network mainnet invocation that still sees the placeholder' — but squad-upgrade.js (read in full) implements NO such guard; it reads cfg.network and proceeds. The threshold is 2-of-3 where TWO of the three signers (Alex Bot server key + Mason key) are both pulled from the SAME 1Password vault on the SAME operator machine for the scripted upgrade — collapsing the 2-of-3 to effectively 1 compromised-host-of-3 for the upgrade path. A malicious program upgrade is total fund loss for every escrowed prize pool. The set-buffer-authority step is also manual and unverified (no check the buffer's bytecode hash matches what was reviewed).  
  _Follow-up:_ Threat-model the upgrade authority: (a) implement the documented placeholder-refusal guard in squad-upgrade.js (fail hard if any mainnet PDA == 1111...); (b) require the two approving keys to come from physically separate custody for any mainnet upgrade (don't co-locate Alex Bot + Mason in one op vault / one host); (c) add a buffer-bytecode-hash confirmation step before approve; (d) document the recovery story if one Squad member key is lost or compromised, and verify the on-chain multisig threshold/members match squad.json.
- **RPC as an unauthenticated trusted oracle (single Helius endpoint, 'confirmed' commitment, rollback)** — chain-trust scoped TxVerifier to instruction shape, but the broader threat class — the Rails app trusts a SINGLE RPC endpoint as ground truth for money decisions — was not given a pass. Every balance/eligibility/verification read uses commitment: 'confirmed' (vault.rb:345/618/1252/1370, not 'finalized'), so a dropped/rolled-back confirmed block can make recover_pending_entry / display_balance / entry_token_balance / withdraw-gate observe state that never finalizes. There is no second-source RPC corroboration and no finalized-commitment gate on the value-bearing reads (token balance, withdrawal eligibility, entry confirmation). A compromised, MITM'd, or merely buggy Helius response (the only RPC, key in 1Password) can lie about ATA balances or PDA existence and the app will credit/admit on it. This compounds the confirmed 'no replay guard on onchain_tx_signature' and 'recover_pending_entry trusts client tx sig' findings.  
  _Follow-up:_ Dedicated RPC-trust pass: enumerate every read that gates money or eligibility and require 'finalized' commitment for those (entry confirmation, token-balance eligibility, withdrawal gate, settlement source data); decide on a corroboration strategy (second RPC / on-program assertion) for high-value reads; and threat-model a hostile/buggy RPC (lies about getAccountInfo/getProgramAccounts/getSignatureStatuses) against the recover-pending-entry and withdrawal flows specifically.
- **Rate-limiting / throttle integrity under the per-process memory_store (rack-attack is effectively disabled in prod)** — The auth-session dimension noted memory_store degrades magic-link replay protection, but did not connect it to the FULL economic/DoS blast radius: production config.cache_store = :memory_store (production.rb:72) and rack-attack defaults to Rails.cache (rack_attack.rb:14 comment), so EVERY throttle counter — login/email brute-force (5/min), wallet-auth verify (10/min), faucet (5/hr), stripe_checkout fee-bleed (10/min), magic-link email spam (3/hr), wallet_withdraw (5/min), prepare_entry (30/min) — is per-dyno and resets on every Heroku restart (daily) and is trivially multiplied across dynos. The app's own docs say Rails.cache MUST be Redis for cross-process correctness, and cable.yml + Sidekiq already use Redis — but the cache_store was left on memory_store. This silently nullifies ~20 throttles that were the documented mitigation for prelaunch-audit H5, OPSEC-019, and the inline-login password oracle. That is a much bigger economic-abuse / credential-stuffing / Stripe-fee-bleed surface than a single medium finding implies.  
  _Follow-up:_ Confirm on the live dyno (heroku run) whether Rack::Attack.cache.store is memory_store, and if so flip config.cache_store to :redis_cache_store (REDIS_URL already present) — this is a one-line prod fix that re-arms every throttle. Then re-run an economic-abuse pass assuming throttles ARE enforced vs NOT, and quantify worst-case Stripe fee bleed, faucet/airdrop SOL burn, and credential-stuffing rate under both. Also add a boot assertion that prod cache is a shared store.
- **Cross-cluster / cross-app signature & state replay (devnet &lt;-&gt; mainnet)** — AuthVerifier binds nonce + host + (optional) User-ID but NOT the Solana cluster/network. The signed login message names only window.location.host; on a future mainnet host the message format is identical. More importantly, on-chain artifacts are NOT cluster-bound in the app's trust checks: the same contest_id (SHA256 of slug) derives the same PDA on devnet and mainnet, and onchain_tx_signature has no uniqueness/replay guard (already a confirmed finding) AND no cluster tag — a devnet tx signature or PDA could be presented to a mainnet-configured app (or vice-versa during the migration window) and pass shape checks. The solana_network_alignment initializer guards BOOT-time env coherence but nothing binds a confirmed-on-chain artifact in the DB to the cluster it came from. With devnet and mainnet apps sharing the same codebase, signer keys (squad.json reuses the SAME member pubkeys for devnet and mainnet), and 1Password secrets, the replay-across-clusters surface deserves explicit coverage before the mainnet flip.  
  _Follow-up:_ Add a cluster discriminator to value-bearing flows: tag onchain_tx_signature / PendingTransaction rows with NETWORK and reject cross-cluster reuse; include the cluster genesis-hash (or 'mainnet'/'devnet') in the SIWS login message and verify it server-side; and confirm the mainnet app uses DISTINCT signer keys from devnet (squad.json currently lists identical members for both) so a devnet key compromise can't authorize anything on mainnet.
- **ActionCable / WebSocket authorization and live-data exposure** — web-layer touched the Sidekiq gate but not the realtime layer. ApplicationCable::Connection is a BARE connection with no identified_by / no reject_unauthorized_connection (connection.rb) — the comment asserts streams are 'public-read' and protected only by Turbo's signed stream names + production allowed_request_origins (production.rb:46). Two things are unaudited: (1) whether the Contest::LiveBroadcast / chat streams ever carry data that should be private (e.g. other users' picks while a contest is open — the app's own design HIDES picks while open, but the live broadcast template renders leaderboard/entry data that a signed-stream subscriber receives in real time), and (2) chat authorization is enforced only at POST time (MessagesController + chat_participant?), while READ is whatever turbo_stream_from signs — so stream-name signing is the ONLY confidentiality boundary on contest chat/leaderboard. allowed_request_origins is a regex on a single host; there's no per-user gate at the socket. For a money contest where pick secrecy is a fairness property, broadcasting any pre-lock entry detail over a public-read stream would be a fairness/integrity bug.  
  _Follow-up:_ Audit every turbo_stream_from / broadcast target (Message + Contest::LiveBroadcast :live and :messages) for what data crosses the wire and at what contest phase; confirm no pre-lock pick/selection data is broadcast; decide whether chat should require an authenticated identified_by connection rather than relying solely on signed stream names; and verify allowed_request_origins covers the mainnet host before launch.
- **Front-running / MEV and transaction-ordering on entry-close and settlement** — vault-statemachine confirmed the 'entry succeeds in the same window settle runs' and 'lock_timestamp can be pushed into the future' races at the contract level, but the MEV/ordering threat was not pursued as its own pass. Concretely: lock is a Clock-vs-timestamp gate with no future-bound, and client TXs are sent skipPreflight:true (lock_contest.js:71, username_rename_form.js:82) with no priority fee. An adversary watching the mempool can (a) race an entry into the block immediately before lock_timestamp using a priority fee while honest entries without priority fees are delayed past the lock, or (b) observe a pending settle_contest (whose winner destination ATA is already-confirmed unconstrained/redirectable) and reorder. Because settlement reads winner/payout data the Rails grader supplies and the destination ATA is decoupled from the entry (existing high finding), ordering games around settle compound that. No priority-fee strategy, no MEV-aware ordering, and no on-program 'entries frozen at settle' invariant were assessed together.  
  _Follow-up:_ Run a dedicated MEV/ordering pass: model an adversary with mempool visibility and priority-fee budget against the lock boundary and the settle transaction; decide whether entries must be hard-frozen (status or a settle-time entry-count snapshot) on-chain before grading rather than relying on time gates; evaluate adding priority fees + retries to honest TXs near the lock; and re-rate the settle destination-ATA finding in light of reorder/sandwich potential.
- **Webhook / payment-provider trust under host-header & idempotency edges (MoonPay + Stripe replay)** — payments-value confirmed the MoonPay payload-amount trust but the wider webhook trust boundary deserves a unified pass. MoonPay's webhook_key is optional (moonpay.rb fails closed ONLY when MOONPAY_ENABLED==true) — if MoonPay is toggled on without the key the webhook accepts unsigned POSTs from anyone (the initializer comment admits this). The C4 host-authorization fix (production.rb:114) allowlists the herokuapp.com direct URL specifically to stop Stripe-signed-payload replay against the dyno — but that direct-dyno URL is still allowlisted, so a captured Stripe event can be replayed at *.herokuapp.com bypassing any CDN/WAF, and webhook controllers skip CSRF/auth by design. Webhook idempotency (replaying the SAME signed Stripe event twice to double-credit) was not explicitly verified end-to-end against the StripePurchase.stripe_session_id uniqueness + TokenPurchaseJob source_ref skip-logic, which is the actual double-mint guard.  
  _Follow-up:_ Unified webhook-trust pass: verify Stripe event idempotency is enforced at the persistence layer (replaying an identical signed event must be a no-op, not a re-credit) and that the herokuapp.com direct URL can't be used to replay signed webhooks; make MOONPAY_WEBHOOK_KEY mandatory whenever the route is drawn (not just when MOONPAY_ENABLED); and confirm refund/chargeback events can't be replayed to un-freeze or re-credit.

<!-- citation-guard: snapshot 2026-05-31 (13 citations) — dated security audit -->
