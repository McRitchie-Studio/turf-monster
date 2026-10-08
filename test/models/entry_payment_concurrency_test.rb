require "test_helper"

# [integration] The two database facts Entry::Payment rests on, raced on real
# connections: the row lock (one entry, two charges) and the unique in-flight
# key (two entries, one player and contest). Non-transactional: each thread
# holds its own connection, so the writes genuinely meet in Postgres.
class EntryPaymentConcurrencyTest < ActiveSupport::TestCase
  include AgentApiTestSupport

  self.use_transactional_tests = false

  setup do
    @contest = contests(:one)
    @user = users(:sam)
    @created = []
  end

  teardown do
    Entry.where(id: @created.map(&:id)).update_all(payment_state: "draft")
    Entry.where(id: @created.map(&:id)).destroy_all
  end

  def pinned_cart(contest: @contest, slot: 0, wallet: "RaceWallet")
    entry = contest.entries.create!(user: @user, status: :cart)
    entry.update_columns(entry_number: slot, wallet_address: wallet)
    @created << entry
    entry
  end

  # Each racer loads its own copy before either charges, then both go at once.
  def race(*entries)
    loaded = Concurrent::CountDownLatch.new(entries.size)
    gate = Concurrent::CountDownLatch.new(1)
    results = Queue.new
    threads = entries.map do |entry|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          racer = Entry.find(entry.id)
          loaded.count_down
          gate.wait(5)
          results << begin
            racer.begin_charge!(rail: "managed")
            :charged
          rescue Entry::Payment::InFlight
            :refused
          end
        end
      end
    end
    loaded.wait(5)
    gate.count_down
    threads.each { |thread| thread.join(10) }
    Array.new(results.size) { results.pop }.sort
  end

  test "two charges racing on one entry: one wins, one is refused (the row lock)" do
    entry = pinned_cart
    assert_equal %i[charged refused], race(entry, entry)
    assert_equal "submitted", entry.reload.payment_state
  end

  test "two carts of one player racing in one contest: one wins (the unique key)" do
    first = pinned_cart(slot: 0)
    second = pinned_cart(slot: 1, wallet: "OtherRail")

    assert_equal %i[charged refused], race(first, second)
    assert_equal 1, Entry.where(id: [first.id, second.id], payment_state: "submitted").count
  end

  test "the unique key is the database's: a write that skips the model is refused too" do
    first = pinned_cart(slot: 0)
    second = pinned_cart(slot: 1)
    first.begin_charge!(rail: "managed")

    assert_raises(ActiveRecord::RecordNotUnique) { second.update_columns(payment_state: "landed") }
  end

  test "CONTROL: after the first returns to draft the second charges; another contest charges at once" do
    first = pinned_cart(slot: 0)
    second = pinned_cart(slot: 1)
    first.begin_charge!(rail: "managed")
    assert_raises(Entry::Payment::InFlight) { second.begin_charge!(rail: "managed") }

    other = Contest.create!(name: "Race Other", slate: @contest.slate, contest_type: @contest.contest_type,
                            entry_fee_cents: @contest.entry_fee_cents, status: :open, starts_at: @contest.starts_at)
    elsewhere = pinned_cart(contest: other)
    assert_equal %i[charged], race(elsewhere)

    first.release_payment!(:expired)
    assert_equal %i[charged], race(second)
  ensure
    Entry.where(contest_id: other&.id).update_all(payment_state: "draft")
    other&.destroy
  end
end
