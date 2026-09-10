# Converge stranded on-chain-paid entries to `active`.
#
# The managed-wallet / entry-token entry path (ContestsController#enter) does an
# IRREVERSIBLE on-chain consume (enter_contest_with_token / enter_contest),
# durably stamps the resulting signature + Entry PDA onto the cart entry, and
# THEN runs the gate-running Entry#confirm!. If confirm! (or its commit) fails
# after the broadcast, the user is paid + entered on-chain but the Rails row
# stays `cart` — showing "not entered" while the token reads consumed. That is
# the 2026-06-08 incident (entry #133, manually reconciled).
#
# This service heals such rows. Two flavors, both idempotent:
#
#   - FAST path: the cart entry already carries `onchain_tx_signature` (the
#     durable-capture write landed). We just re-run confirm! with the stored
#     proof — no RPC needed.
#   - PROBE path: a LEGACY strand (e.g. #133, stranded before the durable
#     capture shipped) has no proof on the Rails row. We probe the chain for an
#     Entry PDA at the wallet's slots, recover the consume signature from
#     getSignaturesForAddress (oldest err:nil), and confirm! with it.
#
# A strand does not always stay in `cart`. ContestsController#clear_picks
# abandons the cart row, and it is the ONLY writer of `abandoned` — so every
# abandoned row is a former cart row, and a strand the user (or the QA rehearsal
# driver, whose EntryFlow clears before every run) cleared afterwards is the same
# stranded payment wearing a different status. Those rows are in reach too, but
# only on proof: see #reconcilable?.
#
# THE TWO ABANDONED STRANDS TAKE DIFFERENT PATHS, and which one a row takes is
# decided by where its proof was written — the same fact that decides whether it
# kept its slot:
#
#   - PHANTOM strand (#prepare_entry / #confirm_onchain_entry) → PROBE path. Its
#     signature is on the PendingTransaction rather than the entry, so
#     Entry#release_slot_if_abandoned — which spares the slot only when the ENTRY
#     carries a signature — nulls its entry_number on the way out. That nil is
#     exactly what makes #find_onchain_entry scan every slot instead of one,
#     which is what finds the PDA the released number no longer points at.
#   - MANAGED strand (ContestsController#enter) → FAST path. The durable capture
#     put the consume signature on the ENTRY, so release_slot_if_abandoned spares
#     the slot and reconcile_entry credits the stored proof without an RPC.
#
# The managed one was UNREACHABLE until `reach-managed-abandoned-strand`: it
# writes no PendingTransaction at all, and a signed PendingTransaction was
# #reconcilable?'s only abandoned admission — so the shape carrying the strongest
# proof available was the one refused. Widened here in BOTH places that decide
# admission (#reconcilable? and #reconcilable_entries), because they are separate
# implementations of one rule.
#
# WHAT THIS SERVICE WILL NOT DO. It only ever PROMOTES a row toward `active`. It
# never deletes one and never rewrites a status downward.
#
# That is a deliberate divergence from the contest-level sweeper being built for
# stranded `pending` CONTEST rows (task `sweep-stranded-pending-contests`), which
# will DELETE a row whose PDA it finds unfunded. No such sweeper exists yet — as
# of 2026-09-06 app/services holds three reconcilers and not one of them deletes
# a row — so treat this paragraph as the reason the verbs are allowed to differ,
# not as a description of code you can go and read.
#
# The reason: a write-ahead contest row is an artifact the app authored and owns,
# so dropping an unfunded one destroys nothing anybody asked for. An `abandoned`
# entry is a record of what a person chose, plus — in the strand case — the only
# surviving pointer to money that already moved. Neither is ours to delete.
#
# Idempotency: an already-active/complete entry is skipped. The unique partial
# index on entries.onchain_tx_signature (plus the explicit pre-check here)
# guarantees one consume signature can never credit two entries, so re-running
# this never double-enters or double-charges.
module Entries
  class OnchainReconciler
    # Heal a single entry. Returns :reconciled / :skipped / :error.
    def self.reconcile_entry(entry, vault: Solana::Vault.new)
      new(vault: vault).reconcile_entry(entry)
    end

    # Sweep eligible contests (or one). Returns a counts hash.
    def self.run(contest: nil, vault: Solana::Vault.new)
      new(vault: vault).run(contest: contest)
    end

    def initialize(vault: Solana::Vault.new)
      @vault = vault
    end

    def run(contest: nil)
      contests = contest ? [contest] : eligible_contests
      stats = Hash.new(0)
      contests.each do |c|
        next unless eligible?(c)
        reconcilable_entries(c).find_each do |entry|
          stats[reconcile_entry(entry)] += 1
        end
      end
      Rails.logger.info(
        "[reconcile][sweep] contests=#{contests.size} " \
        "reconciled=#{stats[:reconciled]} skipped=#{stats[:skipped]} errors=#{stats[:error]}"
      )
      stats
    end

    def reconcile_entry(entry)
      return :skipped if entry.nil?
      entry.reload
      return :skipped unless reconcilable?(entry)

      contest = entry.contest
      return :skipped unless eligible?(contest)

      wallet = entry.user&.solana_address
      return :skipped if wallet.blank?

      sig = entry.onchain_tx_signature.presence
      pda = entry.onchain_entry_id.presence

      if sig.nil?
        # Legacy strand — no proof on the Rails row. Ask the chain.
        pda, sig = find_onchain_entry(contest, wallet, entry)
        return :skipped if sig.nil?
      end

      # Idempotency backstop: never credit a signature already bound to another
      # entry (the DB unique index enforces this too — this gives a clean skip).
      return :skipped if Entry.where.not(id: entry.id).exists?(onchain_tx_signature: sig)

      entry.confirm!(tx_signature: sig, onchain_entry_id: pda)
      Rails.logger.info(
        "[reconcile][healed] entry_id=#{entry.id} contest=#{contest.slug} " \
        "user_id=#{entry.user_id} tx=#{sig.to_s.first(8)}..."
      )
      begin
        Message.announce_join!(contest: contest, user: entry.user)
      rescue StandardError
        # Chat announcement is best-effort — never fail a heal on it.
      end
      :reconciled
    rescue StandardError => e
      # Attach which entry/contest failed to heal so the ErrorLog reads as
      # "entry-<id> in <contest>" rather than a context-free backtrace. `contest`
      # is nil if the fault preceded its assignment (e.g. an entry.reload race).
      error_log = ErrorLog.capture!(e)
      if entry
        error_log.target = entry
        error_log.target_name = entry.slug
      end
      if contest
        error_log.parent = contest
        error_log.parent_name = contest.slug
      end
      error_log.save!
      Rails.logger.error("[reconcile][error] entry_id=#{entry&.id} #{e.class}: #{e.message}")
      :error
    end

    private

    # WHICH ROWS THIS SERVICE MAY TOUCH.
    #
    # `cart` unconditionally — the original strand shape, and the reason this
    # service exists.
    #
    # `abandoned` only on proof of a broadcast. The status alone says nothing:
    # clear_picks abandons a row every time anyone changes their mind, and
    # promoting those would enter people who asked not to be entered. So the
    # question is always "did money move for THIS row?", and there are exactly
    # two places the answer can be recorded, because there are two entry paths:
    #
    #   - ON THE ENTRY (the MANAGED-wallet path, ContestsController#enter). The
    #     durable capture stamps the consume signature onto the still-`cart`
    #     entry and writes no PendingTransaction at all. This is the STRONGEST
    #     proof there is — the consume signature itself — and it is why
    #     release_slot_if_abandoned spared the row's entry_number on the way out.
    #   - ON A PendingTransaction (the PHANTOM path, #prepare_entry /
    #     #confirm_onchain_entry). The signature is stamped there IMMEDIATELY
    #     after the broadcast and BEFORE verification (A1, the double-charge
    #     guard), so it is the durable record that money moved even though the
    #     entry itself never got a signature.
    #
    # Requiring the second alone refused every managed strand — the default
    # onboarding population, since #enter turns away onchain_session? and
    # self_custodied? users. Those users had paid on-chain, held no entry, and the
    # first payment was simply never credited.
    #
    # WHERE THE CONTEST ALLOWS MORE THAN ONE ENTRY they could also pay AGAIN, and
    # the reason is a DB filter rather than the chain: assign_onchain_entry_number!
    # builds `taken` from cart/active/complete only, so the abandoned row is not in
    # it, and the chain probe — which skips an index whose PDA exists — simply
    # moves them on to the NEXT free slot. At max_entries_per_user 1 the probe
    # finds their own PDA at slot 0, returns no free index, and the allocator
    # raises instead: locked out of the contest rather than double-charged. Either
    # way the first payment stays uncredited, which is what this admission fixes.
    # Task `reach-managed-abandoned-strand`, measured in review of PR 560 and
    # re-proven on `accepted` before the fix.
    #
    # `onchain_tx_signature` and NOT `onchain_entry_id`: a comped
    # EnterContestWithToken stamps a PDA and moves no USDC, so a PDA says an
    # Entry account exists, never that anyone paid for it.
    #
    # Both are ADMISSION tests, not the evidence. Nothing is credited from the
    # PendingTransaction: reconcile_entry still recovers the PDA and the consume
    # signature from the chain for a row with no proof of its own, and every row
    # still runs the full Entry#confirm! gate. Proof only buys the row a look.
    def reconcilable?(entry)
      return true if entry.cart?
      return false unless entry.abandoned?

      entry.onchain_tx_signature.present? || broadcast_proof?(entry)
    end

    # Mirrors the polymorphic lookup in ContestsController#confirm_onchain_entry,
    # narrowed to rows that actually carry a signature. Deliberately NOT filtered
    # by PendingTransaction#status: a recovery attempt that failed verification
    # marks the row "failed" (recover_pending_entry) without unspending anything,
    # so status is an opinion about the recovery and the signature is the fact
    # about the broadcast. The chain probe below is what fails this closed.
    def broadcast_proof?(entry)
      PendingTransaction.where(target: entry)
                        .where.not(tx_signature: [nil, ""])
                        .exists?
    end

    # The sweep's candidate set: every `cart` row, plus only those `abandoned`
    # rows a broadcast can be proven for. Resolving the PendingTransaction half
    # through one indexed lookup keeps a contest full of ordinary cleared carts
    # off a row-by-row walk that would call #reconcilable? on each.
    #
    # THIS QUERY IS A SECOND, INDEPENDENT ADMISSION TEST. It does not call
    # #reconcilable?; it re-states the same rule in SQL. So the two must be kept
    # in step by hand, and the failure mode when they drift is silent: the sweep
    # walks a candidate set that never contains the row and prints
    # `reconciled=0` over a live, paid-for strand. Widen one, widen the other.
    def reconcilable_entries(contest)
      abandoned = contest.entries.where(status: :abandoned)
      contest.entries.where(status: :cart)
             .or(abandoned.where.not(onchain_tx_signature: [nil, ""]))
             .or(abandoned.where(id: broadcast_strand_ids(contest)))
    end

    def broadcast_strand_ids(contest)
      PendingTransaction
        .where(target_type: "Entry", target_id: contest.entries.where(status: :abandoned).select(:id))
        .where.not(tx_signature: [nil, ""])
        .distinct
        .pluck(:target_id)
    end

    def eligible_contests
      Contest.where(status: :open).select { |c| eligible?(c) }
    end

    # Limit to contests where an on-chain consume genuinely could have stranded
    # an entry: backed by a Contest PDA AND charging a fee.
    def eligible?(contest)
      contest&.onchain? && contest.entry_fee_cents.to_i.positive?
    end

    # Probe the chain for the wallet's Entry PDA in this contest and recover the
    # consume signature. Prefers the entry's already-assigned slot; otherwise
    # scans 0...max_entries_per_user. Skips a slot already claimed by another of
    # this user's live entries. Returns [entry_pda_b58, signature] or [nil, nil].
    def find_onchain_entry(contest, wallet, entry)
      slots = entry.entry_number ? [entry.entry_number] : (0...contest.max_entries_per_user).to_a
      slots.each do |n|
        pda_b58 = Solana::Keypair.encode_base58(@vault.entry_pda(contest.slug, wallet, n).first)
        next unless onchain_account_exists?(pda_b58)
        next if contest.entries.where(user_id: entry.user_id, onchain_entry_id: pda_b58)
                       .where.not(id: entry.id).exists?
        sig = oldest_success_signature(pda_b58)
        return [pda_b58, sig] if sig
      end
      [nil, nil]
    end

    # Resilient existence check — mainnet RPC rate-limits on bursts, so a single
    # transient error shouldn't read as "PDA absent" and silently skip a paid
    # entry. One brief retry, then treat as absent.
    def onchain_account_exists?(pda_b58)
      attempts = 0
      begin
        attempts += 1
        info = @vault.client.get_account_info(pda_b58)
        !!(info && info["value"])
      rescue StandardError => e
        if attempts < 2
          sleep(0.25)
          retry
        end
        Rails.logger.warn("[reconcile][rpc] get_account_info failed pda=#{pda_b58} #{e.message}")
        false
      end
    end

    # The Entry PDA's first successful signature is the enter_contest(_with_token)
    # that created it (and consumed the token). getSignaturesForAddress returns
    # newest-first, so reverse and take the oldest err:nil entry.
    def oldest_success_signature(pda_b58)
      result = @vault.client.send(:call, "getSignaturesForAddress", [pda_b58, { "limit" => 20 }])
      return nil if result.blank?
      hit = result.reverse.find { |s| s && s["err"].nil? }
      hit && hit["signature"]
    rescue StandardError => e
      Rails.logger.warn("[reconcile][rpc] getSignaturesForAddress failed pda=#{pda_b58} #{e.message}")
      nil
    end
  end
end
