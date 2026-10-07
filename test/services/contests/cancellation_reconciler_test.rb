require "test_helper"

# [unit] Contests::CancellationReconciler marks a contest cancelled in the DB
# ONLY when the chain reads Cancelled AND its prize pool is refunded (balance 0)
# or closed (account absent). Everything else is refused or left alone.
#
# The chain is a fake keyed by slug: `contests` holds the Contest account's
# status (absent key = account absent), `pools` the prize-pool token balance
# (absent key = pool account closed).
class Contests::CancellationReconcilerTest < ActiveSupport::TestCase
  class FakeChain
    attr_reader :contests, :pools, :reads
    attr_accessor :unreadable

    def initialize = (@contests = {}; @pools = {}; @reads = [])

    def read_contest(slug)
      @reads << [:read_contest, slug]
      raise "rpc down" if unreadable

      @contests.key?(slug) ? { status: @contests[slug], prize_pool: 500_000_000 } : nil
    end

    def read_prize_pool_balance(slug)
      @reads << [:read_prize_pool_balance, slug]
      @pools[slug]
    end
  end

  setup { @chain = FakeChain.new }

  def onchain_contest!(chain_status:, pool: :closed, **attrs)
    contest = Contest.create!({ name: "WC #{SecureRandom.hex(3)}", slate: slates(:one), rank: 8000 + rand(900),
                                contest_type: "standard", user: users(:alex), status: "open", max_entries: 29,
                                starts_at: 2.days.from_now, onchain_contest_id: "pda-#{SecureRandom.hex(4)}" }.merge(attrs))
    @chain.contests[contest.slug] = chain_status if chain_status
    @chain.pools[contest.slug] = pool unless pool == :closed
    contest
  end

  def reconcile(write: true, slugs: nil)
    Contests::CancellationReconciler.new(write: write, slugs: slugs, vault: @chain, out: StringIO.new).call
  end

  def row_for(rows, contest) = rows.find { |row| row.slug == contest.slug }

  test "marks a contest whose chain reads Cancelled and whose pool is refunded to zero" do
    contest = onchain_contest!(chain_status: "Cancelled", pool: 0)

    rows = reconcile

    assert_equal :marked, row_for(rows, contest).action
    assert contest.reload.onchain_cancelled?
  end

  test "marks a contest whose chain reads Cancelled and whose pool account is closed" do
    contest = onchain_contest!(chain_status: "Cancelled", pool: :closed)

    assert_equal :marked, row_for(reconcile, contest).action
    assert contest.reload.cancelled?
  end

  test "keeps the DB status: a settled-in-DB contest is marked cancelled and stays settled" do
    # Mainnet contest 34's exact shape: DB status settled, onchain_settled false.
    contest = onchain_contest!(chain_status: "Cancelled", pool: 0, status: "settled")

    reconcile

    contest.reload
    assert contest.cancelled?
    assert contest.settled?
    assert_not contest.onchain_settled?
  end

  test "refuses when the chain reads Cancelled but the pool still holds money" do
    contest = onchain_contest!(chain_status: "Cancelled", pool: 500_000_000)

    row = row_for(reconcile, contest)

    assert_equal :refuse, row.action
    assert_match(/still holds 500000000/, row.reason)
    assert_not contest.reload.onchain_cancelled?
  end

  %w[Open Locked Settled].each do |status|
    test "leaves a contest the chain reads #{status} alone, and never reads its pool" do
      contest = onchain_contest!(chain_status: status, pool: 0)

      assert_equal :in_sync, row_for(reconcile, contest).action
      assert_not contest.reload.onchain_cancelled?
      assert_not_includes @chain.reads, [:read_prize_pool_balance, contest.slug]
    end
  end

  test "refuses when the Contest account is absent: closed-after-settle looks the same" do
    contest = onchain_contest!(chain_status: nil)

    assert_equal :refuse, row_for(reconcile, contest).action
    assert_not contest.reload.onchain_cancelled?
  end

  test "an unreadable chain is an error, never a write" do
    contest = onchain_contest!(chain_status: "Cancelled", pool: 0)
    @chain.unreadable = true

    assert_equal :error, row_for(reconcile, contest).action
    assert_not contest.reload.onchain_cancelled?
  end

  test "a pending (unverified) contest is refused before any chain read" do
    contest = onchain_contest!(chain_status: "Cancelled", pool: 0, status: "pending")

    assert_equal :refuse, row_for(reconcile, contest).action
    assert_empty @chain.reads
    assert_not contest.reload.onchain_cancelled?
  end

  test "a dry run plans the mark and writes nothing" do
    contest = onchain_contest!(chain_status: "Cancelled", pool: 0)

    assert_equal :reconcile, row_for(reconcile(write: false), contest).action
    assert_not contest.reload.onchain_cancelled?
  end

  test "idempotent: a second WRITE run finds nothing to do" do
    contest = onchain_contest!(chain_status: "Cancelled", pool: 0)
    reconcile

    assert_nil row_for(reconcile, contest), "an already-cancelled contest is not a candidate"
    assert_equal :already_cancelled, row_for(reconcile(slugs: [contest.slug]), contest).action
  end

  test "SLUGS scopes the run: an unnamed chain-cancelled contest is untouched; a missing slug is not_found" do
    named = onchain_contest!(chain_status: "Cancelled", pool: 0)
    other = onchain_contest!(chain_status: "Cancelled", pool: 0)

    rows = reconcile(slugs: [named.slug, "no-such-contest"])

    assert named.reload.onchain_cancelled?
    assert_not other.reload.onchain_cancelled?
    assert_equal :not_found, rows.find { |row| row.slug == "no-such-contest" }.action
  end

  test "control: a contest with no on-chain id is never a candidate" do
    offchain = contests(:one)
    assert_nil offchain.onchain_contest_id

    assert_nil row_for(reconcile, offchain)
    assert_not offchain.reload.onchain_cancelled?
  end
end
