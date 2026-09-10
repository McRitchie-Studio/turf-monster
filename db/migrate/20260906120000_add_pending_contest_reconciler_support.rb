# Schema support for Contests::PendingReconciler (PR 2 of the money path).
#
# TWO CHANGES, BOTH SMALL, ONE OF THEM PREVIOUSLY DECLINED ON PURPOSE.
#
# 1. A UNIQUE index on `onchain_contest_id`. This was deliberately declined in
#    PR #551 (harden-finalize-write-ordering) on three grounds the reviewer
#    accepted: that PR added no query on the column; uniqueness already holds
#    STRUCTURALLY (the PDA is sha256(slug) at all five write sites, `slug` is
#    uniquely indexed, and Contest#set_slug is a no-op so a save cannot rewrite
#    the slug underneath a derived PDA); and it was the only change in that PR
#    able to ABORT a release-phase migration on a PR whose entire purpose was
#    reducing deploy risk.
#
#    It belongs here because THIS PR adds the first query that reads the column
#    as an identity — Contests::PendingReconciler re-derives the PDA and
#    compares it to the stored value before deciding whether to delete a row.
#    A structural invariant a reconciler relies on should be enforced by the
#    database, not by five call sites agreeing.
#
#    MEASURED BEFORE WRITING THIS, because a migration that aborts mid-release
#    is worse than the gap it closes (read 2026-09-06, `heroku pg:psql`):
#      * production (turf-monster-mainnet): 8 contests, 4 open + 4 settled, all
#        8 carrying a PDA and a signature. Duplicate onchain_contest_id: 0 rows.
#      * QA (turf-monster-qa): 13 contests. Duplicate onchain_contest_id: 0 rows.
#        2 open rows carry a NULL PDA (QA-only, never on chain).
#    The index is PARTIAL on `IS NOT NULL` for those QA rows' sake. Postgres
#    already treats NULLs as distinct in a unique index, so the predicate buys
#    no correctness — it buys an index that describes its own intent and does
#    not carry entries it can never constrain.
#
# 2. `onchain_reconcile_flagged_at`. The reconciler has a third outcome besides
#    promote and delete: REFUSE, for a row it cannot safely resolve (a PDA that
#    does not match the slug, or an absent PDA on a row that carries a broadcast
#    signature). Those rows stay `pending` and page a human. Without a marker
#    the sweep re-files an identical ErrorLog every 15 minutes forever, so the
#    alert that matters drowns in its own repeats. Nullable, no default, no
#    backfill — every existing row reads "never flagged", which is true.
class AddPendingContestReconcilerSupport < ActiveRecord::Migration[8.0]
  def change
    add_column :contests, :onchain_reconcile_flagged_at, :datetime

    add_index :contests, :onchain_contest_id,
              unique: true,
              where: "onchain_contest_id IS NOT NULL",
              name: "index_contests_on_onchain_contest_id_unique"
  end
end
