# Contest maintenance one-offs.
namespace :contests do
  # Move open, not-yet-locked NFL contests from the old lock (the slate's first
  # kickoff — Thursday on a TNF week) to the opening-Sunday lock
  # (Contest::LockRule). Every guard and the signing path are documented in
  # Contests::ApplyNflSundayLock; read it before WRITE=1.
  #
  #   bin/rails contests:nfl_sunday_lock                       # dry run, every open NFL contest
  #   SLUGS=a,b bin/rails contests:nfl_sunday_lock             # dry run, named contests only
  #   WRITE=1 SLUGS=a,b bin/rails contests:nfl_sunday_lock     # move them (chain first, then DB)
  #
  # Exits 1 when a write was attempted and any contest errored.
  desc "Move open NFL contests' lock to 11:00 Denver on the opening Sunday (dry run unless WRITE=1)"
  task nfl_sunday_lock: :environment do
    write = ENV["WRITE"] == "1"
    rows = Contests::ApplyNflSundayLock.new(write: write, slugs: ENV["SLUGS"].to_s.split(",")).call
    exit 1 if write && rows.any? { |row| row.action == :error }
  end

  # Mark contests cancelled in the DB when the CHAIN shows them cancelled and
  # their prize pool refunded or closed — a cancel signed outside the app's own
  # PendingTransaction flow never flips `onchain_cancelled`. Read-only on chain;
  # writes one boolean; never refunds anyone. Every guard is documented in
  # Contests::CancellationReconciler.
  #
  #   bin/rails contests:reconcile_cancelled                     # dry run, every on-chain contest not yet cancelled
  #   SLUGS=a,b bin/rails contests:reconcile_cancelled           # dry run, named contests only
  #   WRITE=1 SLUGS=a,b bin/rails contests:reconcile_cancelled   # mark them (chain read first, then DB)
  #
  # Exits 1 in WRITE mode when any contest errored or was refused.
  desc "Mark chain-cancelled contests cancelled in the DB (dry run unless WRITE=1)"
  task reconcile_cancelled: :environment do
    write = ENV["WRITE"] == "1"
    rows = Contests::CancellationReconciler.new(write: write, slugs: ENV["SLUGS"].to_s.split(",")).call
    exit 1 if write && rows.any? { |row| Contests::CancellationReconciler::QUIET_ACTIONS.exclude?(row.action) }
  end

  # Every unsettled contest whose payout table has more than
  # Contest::MAX_PAID_RANKS paid ranks, and every unsettled contest with no
  # table (its ranks are those of its format's Contest::PRE_SNAPSHOT_PAYOUTS
  # row, "-" when the format has none). SELECT only; prints no amounts.
  #
  #   bin/rails contests:payout_census
  desc "List unsettled contests whose payout table is over the paid-rank limit or missing (read-only)"
  task payout_census: :environment do
    limit = Contest::MAX_PAID_RANKS
    rows = Contest.where.not(status: "settled").order(:slug)
                  .pluck(:slug, :contest_type, :status, :onchain_cancelled, :payout_table_cents)
    listed = rows.filter_map do |slug, type, status, cancelled, table|
      ranks = (table.presence || Contest::PRE_SNAPSHOT_PAYOUTS[type])&.size
      next unless table.blank? || ranks > limit

      [slug, type, status, cancelled ? "yes" : "no", ranks || "-", table.blank? ? "none" : "snapshot"]
    end

    line = "%-44s %-16s %-8s %-9s %-5s %s"
    puts (line % %w[slug type status cancelled ranks table]).rstrip
    listed.each { |row| puts (line % row).rstrip }
    over = listed.count { |row| row[4].to_i > limit }
    untabled = listed.count { |row| row[5] == "none" }
    puts "#{rows.size} unsettled contest(s) read: #{over} over #{limit} paid ranks, #{untabled} with no table"
  end

  # Replace ONE unsettled contest's payout table with the table passed, in
  # cents, first place first. Refused unless the table has at most
  # Contest::MAX_PAID_RANKS ranks and sums to the contest's current prize pool.
  #
  #   TABLE_CENTS=100000,40000,20000,20000 bin/rails "contests:reshape_payout[slug]"           # dry run
  #   WRITE=1 TABLE_CENTS=100000,40000,20000,20000 bin/rails "contests:reshape_payout[slug]"   # write it
  #
  # Exits 1 on a refusal; a refusal writes nothing.
  desc "Replace one unsettled contest's payout table (dry run unless WRITE=1)"
  task :reshape_payout, [:slug] => :environment do |_task, args|
    contest = Contest.find_by(slug: args[:slug])
    abort "Refused: no contest with slug #{args[:slug].inspect}." unless contest
    abort "Refused: #{contest.slug} is settled." if contest.settled? || contest.onchain_settled?

    table = ENV["TABLE_CENTS"].to_s.split(",").map { |cents| Integer(cents.strip, 10, exception: false) }
    unless table.any? && table.all? { |cents| cents&.positive? }
      abort "Refused: TABLE_CENTS must be comma-separated positive integer cents, first place first."
    end
    if table.size > Contest::MAX_PAID_RANKS
      abort "Refused: #{table.size} paid ranks; one settlement pays at most #{Contest::MAX_PAID_RANKS}."
    end
    pool = contest.guaranteed_prize_cents
    abort "Refused: the table sums to #{table.sum} cents; the pool is #{pool} cents." unless table.sum == pool

    puts "#{contest.slug}: #{contest.payouts.values.inspect} -> #{table.inspect}"
    if ENV["WRITE"] == "1"
      # update_all, because the column is attr_readonly on the model.
      Contest.where(id: contest.id).update_all(payout_table_cents: table)
      puts "Written."
    else
      puts "Dry run: nothing written. WRITE=1 writes it."
    end
  end
end
