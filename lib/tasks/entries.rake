# Reconcile stranded on-chain-paid entries.
#
# The managed-wallet / entry-token entry path does an irreversible on-chain
# consume, then runs the gate-running Entry#confirm!. A post-broadcast confirm
# failure leaves the Rails entry in `cart` while the user is paid + entered on
# chain (the 2026-06-08 incident, entry #133). This sweeps such rows and
# converges them to `active` — both the new recoverable strands (cart row
# already carries onchain_tx_signature) and legacy ones (no proof on the row →
# probes the chain for the Entry PDA + recovers the consume signature).
#
# WHICH ROWS THIS TOUCHES — read this before running it over money:
#
#   - every `cart` row in an eligible contest, and
#   - an `abandoned` row ONLY when a broadcast can be proven for it, which is
#     the consume signature on the ENTRY (the managed path's durable capture)
#     or a signed PendingTransaction targeting it (the Phantom path).
#
# An `abandoned` row is a strand somebody cleared afterwards — clear_picks is
# the only writer of that status — so it is the same paid-for entry wearing a
# different status. An abandoned row with NO such proof is an ordinary cleared
# cart and is never promoted: activating those would enter people who asked not
# to be entered.
#
# Idempotent: nothing is credited without proof, every heal runs the full
# Entry#confirm! gate, and the unique signature index guarantees one consume can
# never credit two entries. Safe to re-run / cron.
#
#   bin/rails entries:reconcile_onchain                 # all eligible open contests
#   bin/rails entries:reconcile_onchain[world-cup-week-1]  # one contest by slug
namespace :entries do
  desc "Converge stranded on-chain-paid entries to active — every cart row, plus abandoned rows " \
       "proven paid by a signature on the entry or a signed PendingTransaction (optionally one contest slug)"
  task :reconcile_onchain, [:contest_slug] => :environment do |_t, args|
    contest = nil
    if args[:contest_slug].present?
      contest = Contest.find_by(slug: args[:contest_slug])
      abort "No contest with slug #{args[:contest_slug].inspect}" unless contest
    end

    stats = Entries::OnchainReconciler.run(contest: contest)
    puts "reconciled=#{stats[:reconciled]} skipped=#{stats[:skipped]} errors=#{stats[:error]}"
  end
end
