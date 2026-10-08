require "test_helper"

# [unit] Entry::Payment: the transition table, the slot pin, the in-flight key
# and the guards that keep an unresolved payment's row in place.
class EntryPaymentTest < ActiveSupport::TestCase
  include AgentApiTestSupport

  setup do
    @contest = make_onchain!(contests(:one))
    @user = make_managed!(users(:sam))
    @wallet = @user.web2_solana_address
    @vault = LedgerVault.new
  end

  def cart(user: @user, contest: @contest, picks: fixture_matchups)
    entry = contest.entries.create!(user: user, status: :cart)
    picks.each { |matchup| entry.selections.create!(slate_matchup: matchup) }
    entry
  end

  def pinned(entry = cart, wallet: @wallet)
    on_chain(@vault) { entry.pin_payment_slot!(wallet, @vault) }
    entry
  end

  def submitted(entry = pinned)
    entry.begin_charge!(rail: "managed")
  end

  # --- the table ---------------------------------------------------------------

  test "every legal move is taken and every other pair raises, leaving the row as it was" do
    states = Entry::Payment::STATES
    states.product(states).each do |from, to|
      next if from == to

      entry = pinned(cart(picks: []))
      entry.update_columns(payment_state: from)
      legal = Entry::Payment::TRANSITIONS.fetch(from).include?(to)

      if legal
        entry.transition_payment!(to)
        assert_equal to, entry.reload.payment_state, "#{from} → #{to}"
      else
        assert_raises(Entry::Payment::IllegalTransition, "#{from} → #{to}") { entry.transition_payment!(to) }
        assert_equal from, entry.reload.payment_state, "#{from} → #{to} must not move the row"
      end
      entry.update_columns(payment_state: "draft")
      entry.destroy!
    end
  end

  test "a landed row never returns to draft: the player paid" do
    entry = submitted
    entry.mark_payment_landed!(code: :contest_locked, signature: "sig-1")

    assert_raises(Entry::Payment::IllegalTransition) { entry.release_payment!(:expired) }
    assert_equal %w[landed contest_locked sig-1], entry.reload.values_at(:payment_state, :payment_refusal_code, :payment_signature)
    assert_equal %w[confirmed], Entry::Payment::TRANSITIONS.fetch("landed")
  end

  test "CONTROL: a submitted row does return to draft, with its picks and the reason" do
    entry = submitted
    entry.release_payment!(:expired)

    assert_equal %w[draft expired], entry.reload.values_at(:payment_state, :payment_refusal_code)
    assert_equal 6, entry.selections.count
  end

  test "activating an entry by any path confirms its payment" do
    entry = submitted
    entry.update!(status: :active)
    assert_equal "confirmed", entry.reload.payment_state

    assert_equal "confirmed", enter!(users(:jordan), @contest, fixture_matchups).payment_state, "a row created active"
  end

  # --- the pin -----------------------------------------------------------------

  test "the pin is probed once and reused: a ticket landing at the slot does not move the row" do
    entry = pinned
    assert_equal [0, @wallet], entry.values_at(:entry_number, :wallet_address)

    probes = 0
    @vault.before_slot_probe = -> { probes += 1 }
    @vault.send(:land!, @wallet, @contest.slug, 0, :usdc) { nil } # the first attempt landed
    on_chain(@vault) { entry.pin_payment_slot!(@wallet, @vault) }

    assert_equal 0, entry.reload.entry_number, "the retry keeps the slot its first payment used"
    assert_equal 0, probes
  end

  test "CONTROL: an unpinned row is probed, and takes the next slot when a ticket is there" do
    @vault.send(:land!, @wallet, @contest.slug, 0, :usdc) { nil } # an orphan ticket
    assert_equal 1, pinned.entry_number
  end

  test "a draft row may be pinned to the player's other wallet; a submitted row may not" do
    entry = pinned
    on_chain(@vault) { entry.pin_payment_slot!("OtherWallet", @vault) }
    assert_equal "OtherWallet", entry.reload.wallet_address

    entry.begin_charge!(rail: "phantom")
    error = assert_raises(Entry::Payment::InFlight) { on_chain(@vault) { entry.pin_payment_slot!(@wallet, @vault) } }
    assert_equal :payment_in_flight, error.code
    assert_equal "OtherWallet", entry.reload.wallet_address
  end

  # --- the in-flight key ---------------------------------------------------------

  test "a second charge on a submitted row is refused with the row and a message" do
    entry = submitted
    error = assert_raises(Entry::Payment::InFlight) { entry.begin_charge!(rail: "managed") }

    assert_equal entry, error.entry
    assert_match(/still confirming/, error.message)
    assert_kind_of Entry::Refusal, error
  end

  test "another cart of the same player in the same contest is refused, on either wallet" do
    first = submitted
    second = cart(picks: fixture_matchups.first(5))
    error = assert_raises(Entry::Payment::InFlight) { pinned(second, wallet: "PhantomWallet") && second.begin_charge!(rail: "phantom") }
    assert_equal first, error.entry

    first.mark_payment_landed!(code: :contest_locked)
    landed = assert_raises(Entry::Payment::InFlight) { second.begin_charge!(rail: "phantom") }
    assert_match(/will not be charged again/, landed.message)
  end

  test "CONTROL: another contest, another player, and the same player once the first settles all charge" do
    first = submitted
    other_contest = make_onchain!(Contest.create!(name: "Other", slate: @contest.slate, contest_type: @contest.contest_type,
                                                  entry_fee_cents: @contest.entry_fee_cents, status: :open,
                                                  starts_at: @contest.starts_at))
    assert_equal "submitted", submitted(pinned(cart(contest: other_contest))).payment_state
    assert_equal "submitted", submitted(pinned(cart(user: make_managed!(users(:jordan))), wallet: users(:jordan).web2_solana_address)).payment_state

    first.release_payment!(:expired)
    second = cart(picks: fixture_matchups.first(5))
    assert_equal "submitted", submitted(pinned(second)).payment_state
  end

  test "a row a callback-skipping writer activated does not hold the key" do
    first = submitted
    first.update_columns(status: "active")

    assert_nil Entry.payment_in_flight_for(user: @user, contest: @contest)
    assert_equal "confirmed", first.reload.payment_state
    assert_equal "submitted", submitted(pinned(cart(picks: fixture_matchups.first(5)))).payment_state
  end

  test "a charge needs a draft cart with a pinned slot" do
    assert_raises(Entry::Payment::IllegalTransition) { cart.begin_charge!(rail: "managed") }
    assert_raises(Entry::Payment::IllegalTransition) { enter!(@user, @contest, fixture_matchups).begin_charge!(rail: "managed") }
  end

  # --- the signature, before the send ---------------------------------------------

  test "the attempt is recorded only on a submitted row, so a released attempt sends nothing" do
    entry = submitted
    entry.record_payment_attempt!(signature: "sig-1", last_valid_block_height: 500)
    assert_equal ["sig-1", 500], entry.reload.values_at(:payment_signature, :payment_last_valid_block_height)

    entry.release_payment!(:expired)
    assert_raises(Entry::Payment::IllegalTransition) { entry.record_payment_attempt!(signature: "sig-2") }
    assert_equal "sig-1", entry.reload.payment_signature
  end

  test "an attempt lapses by block height when one was recorded, never before it" do
    entry = submitted
    entry.record_payment_attempt!(signature: "sig-1", last_valid_block_height: 500)

    refute entry.payment_attempt_lapsed?(finalized_block_height: 500, now: 1.day.from_now)
    assert entry.payment_attempt_lapsed?(finalized_block_height: 501)
  end

  test "an attempt with no signature sent nothing and lapses after the grace; an undated sent one after ten minutes" do
    entry = submitted
    refute entry.payment_attempt_lapsed?(finalized_block_height: 9_999, now: 29.seconds.from_now)
    assert entry.payment_attempt_lapsed?(finalized_block_height: 0, now: 31.seconds.from_now)

    entry.record_payment_attempt!(signature: "sig-1")
    refute entry.payment_attempt_lapsed?(finalized_block_height: 9_999, now: 9.minutes.from_now)
    assert entry.payment_attempt_lapsed?(finalized_block_height: 0, now: 11.minutes.from_now)
  end

  # --- the row stays --------------------------------------------------------------

  test "an in-flight row cannot be edited, destroyed or abandoned" do
    entry = submitted
    error = assert_raises(Entry::Payment::InFlight) { entry.toggle_selection!(slate_matchups(:m1)) }
    assert_equal :payment_in_flight, error.code
    assert_equal 6, entry.selections.count

    refute entry.destroy, "destroy is halted"
    assert_equal 0, @user.entries.cart.destroy_all.count { |row| row.destroyed? }
    assert Entry.exists?(entry.id)
    assert_equal 6, entry.selections.count, "the halted destroy took no picks with it"

    refute entry.update(status: :abandoned)
    assert_match(/still confirming/, entry.errors.full_messages.to_sentence)
    assert entry.reload.cart?
  end

  test "CONTROL: a draft row toggles down to nothing, is destroyed, and can be abandoned" do
    entry = pinned
    fixture_matchups.each { |matchup| entry.toggle_selection!(matchup) }
    refute Entry.exists?(entry.id), "removing the last pick destroys a draft cart"

    other = pinned(cart)
    other.update!(status: :abandoned)
    assert other.reload.abandoned?
  end
end
