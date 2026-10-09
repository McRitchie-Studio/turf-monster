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

  # --- the attempt token: every write is a compare-and-set ------------------------------

  # Attempt A began and stalled. A settlement released it and the player's
  # retry B began on the same row. Then A wakes on its own connection, holding
  # its stale copy and its old token, and tries everything an attempt can do,
  # while B records its signature on another.
  test "a stalled attempt racing its replacement can neither sign, release nor move the newer attempt's row" do
    entry = pinned_cart
    stale = Entry.find(entry.id).begin_charge!(rail: "managed") # A, holding token A
    old_token = stale.payment_attempt_token
    assert Entry.find(entry.id).release_unsent_attempt!(old_token, :not_sent), "the settlement releases unsent A"
    current = Entry.find(entry.id).begin_charge!(rail: "managed") # B
    refute_equal old_token, current.payment_attempt_token

    gate = Concurrent::CountDownLatch.new(1)
    outcomes = Queue.new
    waking = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        gate.wait(5)
        outcomes << [:release, stale.release_unsent_attempt!(old_token, :too_late)]
        outcomes << [:sign, (stale.record_payment_attempt!(signature: "sig-A", token: old_token) rescue $!.class)]
        outcomes << [:move, (Entry.find(entry.id).tap { |row| row.payment_attempt_token = old_token }.transition_payment!("draft") rescue $!.class)]
      end
    end
    sending = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        gate.wait(5)
        current.record_payment_attempt!(signature: "sig-B", last_valid_block_height: 500)
      end
    end
    gate.count_down
    [waking, sending].each { |thread| thread.join(10) }

    assert_equal({ release: false, sign: Entry::Payment::Superseded, move: Entry::Payment::Superseded },
                 Array.new(outcomes.size) { outcomes.pop }.to_h)
    assert_equal ["submitted", "sig-B", 500, nil, current.payment_attempt_token],
                 entry.reload.values_at(:payment_state, :payment_signature, :payment_last_valid_block_height,
                                        :payment_refusal_code, :payment_attempt_token)
  end

  test "CONTROL: the attempt that holds the row signs it, and releases it only while it is unsigned" do
    entry = pinned_cart.begin_charge!(rail: "managed")
    token = entry.payment_attempt_token

    assert Entry.find(entry.id).release_unsent_attempt!(token, :too_late), "its own unsigned row"
    assert_equal %w[draft too_late], entry.reload.values_at(:payment_state, :payment_refusal_code)

    entry.begin_charge!(rail: "managed")
    entry.record_payment_attempt!(signature: "sig-1")
    refute entry.release_unsent_attempt!(entry.payment_attempt_token, :too_late), "a signed row is never 'nothing was sent'"
    assert_equal "submitted", entry.reload.payment_state
  end

  # Clear Picks loaded the cart as a draft; a charge then takes the row and has
  # not committed. The clear waits on the row lock and reads what the charge wrote.
  test "a clear that meets a charge holding the row waits for it, then keeps the cart, slot and key" do
    entry = pinned_cart
    clearing = Entry.find(entry.id)
    charged = Concurrent::CountDownLatch.new(1)
    release = Concurrent::CountDownLatch.new(1)
    charge = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Entry.transaction do
          Entry.find(entry.id).begin_charge!(rail: "managed")
          charged.count_down
          release.wait(5)
        end
      end
    end
    assert charged.wait(5)
    clear = Thread.new { ActiveRecord::Base.connection_pool.with_connection { clearing.abandon_draft_cart! } }
    sleep 0.5
    assert clear.alive?, "the clear is waiting on the charge's row lock"
    release.count_down

    assert_equal false, clear.value
    assert_equal ["cart", "submitted", 0], entry.reload.values_at(:status, :payment_state, :entry_number)
  ensure
    release&.count_down
    [charge, clear].compact.each { |thread| thread.join(10) }
  end
end
