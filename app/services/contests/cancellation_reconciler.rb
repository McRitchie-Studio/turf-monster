# Brings `contests.onchain_cancelled` in line with the chain for a contest that
# was cancelled OUTSIDE the app's own cancel flow. The app flips the flag only
# when an admin confirms a `cancel_contest` PendingTransaction
# (Admin::PendingTransactionsController#confirm); a cancel signed anywhere else
# (Squads, a CLI) leaves the row reading "not cancelled" forever. Mainnet
# contest 34 (world-cup-week-1-turf-totals) is the case that found this: cancelled
# on chain, yet still `onchain_cancelled: false` months later.
#
# DRY RUN BY DEFAULT. Nothing is written unless `write: true`
# (`WRITE=1 bin/rails contests:reconcile_cancelled`). Idempotent: a contest that
# already reads cancelled is not a candidate, and a second run writes nothing.
#
# THE CHAIN IS READ FIRST, EVERY TIME, and the DB is written only when BOTH hold:
#
#   * the Contest account's status byte reads `Cancelled`, and
#   * the prize-pool token account is EMPTY (balance 0) or CLOSED (absent) —
#     i.e. the pool was refunded to the creator, which cancel_contest does in
#     the same instruction. The Contest account's own `prize_pool` field is not
#     this check: it records what was funded and is never decremented.
#
# WHAT IT REFUSES, contest by contest:
#
#   * a chain it cannot read (RPC error). Fail closed.
#   * a Contest account that is ABSENT. close_contest runs after settle OR
#     cancel, so a closed account cannot tell the two apart.
#   * `Cancelled` with money still in the pool — the chain contradicts itself;
#     a human looks before the DB says anything.
#   * a contest not yet verified on chain (`pending`).
#
# WHAT IT NEVER DOES: send or sign a transaction, or refund anybody. It writes
# one boolean. cancel_contest returns the PRIZE POOL to the creator; entrants'
# fees are not touched by it, and compensating them is a human decision
# (docs/runbooks/cancelled-contest-refunds.md).
module Contests
  class CancellationReconciler
    Row = Struct.new(:contest_id, :slug, :action, :chain_status, :pool_balance, :reason, keyword_init: true)

    # Actions that mean "this run did nothing wrong" — anything else in WRITE
    # mode is worth a non-zero exit from the rake task.
    QUIET_ACTIONS = %i[marked reconcile in_sync already_cancelled not_found].freeze

    def initialize(write: false, slugs: nil, vault: nil, out: $stdout)
      @write = write
      @slugs = Array(slugs).map(&:to_s).reject(&:blank?)
      @vault = vault
      @out = out
    end

    def call
      rows = candidate_rows
      report(rows)
      rows
    end

    private

    def candidate_rows
      scope = Contest.where.not(onchain_contest_id: [nil, ""]).order(:id)
      return scope.where(onchain_cancelled: false).map { |contest| process(contest) } if @slugs.empty?

      found = scope.where(slug: @slugs).index_by(&:slug)
      @slugs.map do |slug|
        contest = found[slug]
        next Row.new(slug: slug, action: :not_found, reason: "no on-chain contest with this slug here") unless contest
        next Row.new(contest_id: contest.id, slug: slug, action: :already_cancelled, reason: "DB already reads cancelled") if contest.onchain_cancelled?

        process(contest)
      end
    end

    def process(contest)
      row = plan(contest)
      return row unless @write && row.action == :reconcile

      apply(contest, row)
    rescue StandardError => e
      ErrorLog.capture!(e)
      Row.new(contest_id: contest.id, slug: contest.slug, action: :error, reason: "#{e.class}: #{e.message.to_s[0, 200]}")
    end

    # Read-only. Every chain read for a contest happens here, before apply.
    def plan(contest)
      row = Row.new(contest_id: contest.id, slug: contest.slug)
      return finish(row, :refuse, "not verified on chain (pending)") if contest.pending?

      onchain = vault.read_contest(contest.slug)
      return finish(row, :refuse, "contest account absent: closed after settle or cancel cannot be told apart") unless onchain

      row.chain_status = onchain[:status]
      return finish(row, :in_sync, "chain reads #{onchain[:status]}") unless onchain[:status] == "Cancelled"

      row.pool_balance = vault.read_prize_pool_balance(contest.slug)
      return finish(row, :reconcile, "cancelled on chain, prize pool closed") if row.pool_balance.nil?
      return finish(row, :reconcile, "cancelled on chain, prize pool refunded (balance 0)") if row.pool_balance.zero?

      finish(row, :refuse, "chain reads Cancelled but the prize pool still holds #{row.pool_balance} base units")
    end

    def apply(contest, row)
      contest.with_lock do
        # Re-read under the lock: a confirm of the app's own cancel flow may
        # have landed between plan and here. Either way the end state is the same.
        contest.update!(onchain_cancelled: true) unless contest.onchain_cancelled?
      end
      finish(row, :marked, row.reason)
    end

    def finish(row, action, reason)
      row.action = action
      row.reason = reason
      row
    end

    def vault
      @vault ||= Solana::Vault.new
    end

    def report(rows)
      @out.puts(@write ? "WRITE — marking chain-cancelled contests cancelled" : "DRY RUN — nothing written (WRITE=1 to apply)")
      @out.puts("#{rows.size} contest(s) checked")
      rows.each do |row|
        @out.puts(format("  %-17s id=%-6s %-44s chain=%-10s pool=%-12s %s",
                         row.action, row.contest_id || "-", row.slug, row.chain_status || "-",
                         row.pool_balance.nil? ? "-" : row.pool_balance, row.reason))
      end
    end
  end
end
