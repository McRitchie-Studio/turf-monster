require "test_helper"
require "rake"

# [integration] contests:reconcile_cancelled, end to end through the rake task,
# with the RPC stubbed at the Solana::Vault boundary.
#
# Two things are proven here that the unit test cannot see:
#
#   1. THE CHAIN IS READ BEFORE ANY DATABASE WRITE. One ordered log records both
#      the vault reads and every INSERT/UPDATE/DELETE the run issues, so a write
#      that slipped ahead of the read fails on position, not on outcome.
#   2. THE REFUND IS ONLY PREPARED. The vault fake answers ONLY the two read
#      methods; any other call (a mint, a transfer, a cancel/settle build, a
#      broadcast) raises. And no money-ledger row appears: TransactionLog,
#      PendingTransaction, EntryGift, StripePurchase counts are unchanged and the
#      entrant's entry is untouched. Compensating an entrant is a human step
#      (docs/runbooks/cancelled-contest-refunds.md).
class ContestsReconcileCancelledTaskTest < ActiveSupport::TestCase
  # Strict: a BasicObject with exactly the reads, so a write-path call is a
  # NoMethodError instead of a silently stubbed success.
  class ReadOnlyChain < BasicObject
    def initialize(log, contests:, pools:)
      @log = log
      @contests = contests
      @pools = pools
    end

    def read_contest(slug)
      @log << [:chain, :read_contest, slug]
      @contests.key?(slug) ? { status: @contests[slug], prize_pool: 500_000_000 } : nil
    end

    def read_prize_pool_balance(slug)
      @log << [:chain, :read_prize_pool_balance, slug]
      @pools[slug]
    end

    def method_missing(name, *)
      @log << [:chain, :FORBIDDEN, name]
      ::Kernel.raise ::NoMethodError, "read-only chain fake: #{name} is not a read"
    end

    # Minitest's stub asks the value whether it is callable; answer for the reads only.
    def respond_to?(name, *) = %i[read_contest read_prize_pool_balance].include?(name)
  end

  WRITE_SQL = /\A\s*(INSERT|UPDATE|DELETE)\b/i

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("contests:reconcile_cancelled")
    @log = []
    @cancelled = make_contest!(status: "settled") # contest 34's shape: settled in DB, never graded
    @open = make_contest!(status: "open")
    @entry = Entry.create!(contest: @cancelled, user: users(:jordan), status: "active",
                           onchain_tx_signature: "sig-#{SecureRandom.hex(8)}", onchain_entry_id: "entry-pda")
    @chain = ReadOnlyChain.new(@log, contests: { @cancelled.slug => "Cancelled", @open.slug => "Open" },
                                     pools: { @cancelled.slug => 0, @open.slug => 140_000_000 })
  end

  teardown { %w[WRITE SLUGS].each { |key| ENV.delete(key) } }

  def make_contest!(status:)
    Contest.create!(name: "WC #{SecureRandom.hex(3)}", slate: slates(:one), rank: 8000 + rand(900),
                    contest_type: "standard", user: users(:alex), status: status, max_entries: 29,
                    starts_at: 2.days.from_now, onchain_contest_id: "pda-#{SecureRandom.hex(4)}")
  end

  def run_task(write:, slugs: nil)
    ENV["WRITE"] = write ? "1" : nil
    ENV["SLUGS"] = slugs&.join(",")
    callback = ->(*, payload) { @log << [:sql, payload[:sql]] if payload[:sql].to_s.match?(WRITE_SQL) }
    exit_status = nil
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      Solana::Vault.stub(:new, @chain) do
        capture_io do
          Rake::Task["contests:reconcile_cancelled"].reenable
          Rake::Task["contests:reconcile_cancelled"].invoke
        rescue SystemExit => e
          exit_status = e.status
        end
      end
    end
    exit_status
  end

  def ledger_counts
    [TransactionLog, PendingTransaction, EntryGift, StripePurchase].to_h { |model| [model.name, model.count] }
  end

  test "the on-chain check runs before the database write, and the write is the one flag" do
    run_task(write: true)

    first_write = @log.index { |event| event.first == :sql }
    assert first_write, "expected the reconcile to write"
    reads_before = @log.first(first_write).select { |event| event.first == :chain }
    assert_includes reads_before, [:chain, :read_contest, @cancelled.slug]
    assert_includes reads_before, [:chain, :read_prize_pool_balance, @cancelled.slug]

    writes = @log.select { |event| event.first == :sql }.map(&:last)
    assert writes.all? { |sql| sql.match?(/\AUPDATE "contests"/) }, "only contests rows may be written: #{writes.inspect}"
    assert @cancelled.reload.onchain_cancelled?
    assert_not @open.reload.onchain_cancelled?
  end

  test "the refund is only prepared: no chain write, no ledger row, the entry untouched" do
    before = ledger_counts
    entry_before = @entry.reload.attributes

    status = run_task(write: true)

    assert_nil status, "a clean WRITE run must not exit non-zero"
    assert_empty @log.select { |event| event[1] == :FORBIDDEN }, "the reconcile called a non-read vault method"
    assert_equal before, ledger_counts
    assert_equal entry_before, @entry.reload.attributes
  end

  test "dry run: chain read, zero database writes" do
    run_task(write: false)

    assert(@log.any? { |event| event == [:chain, :read_contest, @cancelled.slug] })
    assert_empty @log.select { |event| event.first == :sql }
    assert_not @cancelled.reload.onchain_cancelled?
  end

  test "a refusal in WRITE mode exits 1 and writes nothing (post_deploy_cmd fails loud)" do
    @chain = ReadOnlyChain.new(@log, contests: { @cancelled.slug => "Cancelled" }, pools: { @cancelled.slug => 500_000_000 })

    status = run_task(write: true, slugs: [@cancelled.slug])

    assert_equal 1, status
    assert_empty @log.select { |event| event.first == :sql }
    assert_not @cancelled.reload.onchain_cancelled?
  end

  test "the post_deploy_cmd shape is idempotent and a slug absent on this app exits clean" do
    assert_nil run_task(write: true, slugs: [@cancelled.slug, "world-cup-week-1-turf-totals"])
    assert @cancelled.reload.onchain_cancelled?

    @log.clear
    assert_nil run_task(write: true, slugs: [@cancelled.slug])
    assert_empty @log.select { |event| event.first == :sql }, "second run must write nothing"
  end
end
