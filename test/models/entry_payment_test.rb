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

  # --- the pin does not move under a wire that can still pay ---------------------------

  def prepared_wire(entry, wallet:, age: 0.seconds, signature: nil)
    PendingTransaction.create!(tx_type: "enter_contest", serialized_tx: "stx", target: entry, initiator_address: wallet,
                               status: signature ? "submitted" : "pending", tx_signature: signature,
                               created_at: age.ago, metadata: {}.to_json)
  end

  test "a cart with a wire prepared on the other rail cannot be re-pinned: the second rail is refused" do
    entry = pinned(cart, wallet: "PhantomWallet")
    prepared_wire(entry, wallet: "PhantomWallet")

    error = assert_raises(Entry::Payment::PinHeld) { on_chain(@vault) { entry.pin_payment_slot!(@wallet, @vault) } }
    assert_equal :payment_started_elsewhere, error.code
    assert_match(/started in another session.*not charged/, error.message)
    assert_equal ["PhantomWallet", 0], entry.reload.values_at(:wallet_address, :entry_number), "wallet and slot stay together"
  end

  test "CONTROL: once the unsigned wire is too old to be signed and sent, the pin may move" do
    entry = pinned(cart, wallet: "PhantomWallet")
    prepared_wire(entry, wallet: "PhantomWallet", age: 6.minutes)

    on_chain(@vault) { entry.pin_payment_slot!(@wallet, @vault) }
    assert_equal @wallet, entry.reload.wallet_address
  end

  test "the pin does not move off a ticket that exists, or one that cannot be read" do
    entry = pinned(cart, wallet: "PhantomWallet")
    entry.update_columns(payment_rail: "managed") # activated without the wallet verifier, which has its own tests
    @vault.chain_unreadable = true
    assert_raises(Entry::Payment::InFlight) { on_chain(@vault) { entry.pin_payment_slot!(@wallet, @vault) } }
    assert_equal "PhantomWallet", entry.reload.wallet_address, "unreadable: nothing moves"

    @vault.chain_unreadable = false
    @vault.send(:land!, "PhantomWallet", @contest.slug, 0, :usdc) { nil }
    assert_raises(Entry::Payment::InFlight) { on_chain(@vault) { entry.pin_payment_slot!(@wallet, @vault) } }
    assert entry.reload.active?, "the ticket at the old pin is this entry's payment: confirmed, not abandoned"
    assert_equal "PhantomWallet", entry.wallet_address
  end

  test "a Phantom wire is refused at its send when the cart is no longer pinned to the wallet it pays from" do
    entry = pinned(cart, wallet: @wallet) # the managed rail holds the pin now

    assert_raises(Entry::Payment::PinMoved) do
      entry.begin_phantom_charge!(signature: "phantom-sig", wallet: "PhantomWallet", last_valid_block_height: 500)
    end
    assert_equal ["draft", @wallet, nil], entry.reload.values_at(:payment_state, :wallet_address, :payment_signature),
                 "the wallet is not adopted over an existing pin, and nothing is recorded"
  end

  test "a Phantom wire is refused at its send when the cart's ticket is no longer the one the wire names" do
    entry = pinned(cart, wallet: "PhantomWallet")
    wire_ticket = on_chain(@vault) { entry.payment_entry_pda(@vault) }
    entry.update_columns(entry_number: 1) # the slot moved under the prepared wire

    on_chain(@vault) do
      assert_raises(Entry::Payment::PinMoved) do
        entry.begin_phantom_charge!(signature: "phantom-sig", wallet: "PhantomWallet", prepared_pda: wire_ticket)
      end
    end
    assert_equal "draft", entry.reload.payment_state
  end

  test "CONTROL: the wire for the row's own pin begins the charge; a never-pinned row takes the signing wallet" do
    entry = pinned(cart, wallet: "PhantomWallet")
    wire_ticket = on_chain(@vault) { entry.payment_entry_pda(@vault) }
    on_chain(@vault) { entry.begin_phantom_charge!(signature: "phantom-sig", wallet: "PhantomWallet", prepared_pda: wire_ticket) }
    assert_equal %w[submitted phantom-sig], entry.reload.values_at(:payment_state, :payment_signature)

    legacy = @contest.entries.create!(user: make_managed!(users(:jordan)), status: :cart, entry_number: 0)
    legacy.begin_phantom_charge!(signature: "legacy-sig", wallet: "LegacyWallet")
    assert_equal %w[submitted LegacyWallet], legacy.reload.values_at(:payment_state, :wallet_address)
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

  # --- the one release rule ---------------------------------------------------------

  LANDED = { "err" => nil, "confirmationStatus" => "finalized" }.freeze
  FAILED = { "err" => { "InstructionError" => [0, { "Custom" => 6004 }] }, "confirmationStatus" => "finalized" }.freeze

  def allowed?(entry, status: nil, height: 501, now: Time.current)
    entry.payment_release_allowed?(status: status, finalized_block_height: height, now: now)
  end

  test "an unsigned attempt sent nothing: released after the grace, whatever the height" do
    entry = submitted
    refute allowed?(entry, height: 9_999, now: 29.seconds.from_now), "CONTROL: a live request may still be about to send"
    assert allowed?(entry, height: nil, now: 31.seconds.from_now)
  end

  test "a signed managed attempt is released only past its recorded height, with no status" do
    entry = submitted
    entry.record_payment_attempt!(signature: "sig-1", last_valid_block_height: 500)

    refute allowed?(entry, height: 500, now: 1.day.from_now), "at the last valid block the wire can still land"
    refute allowed?(entry, height: nil, now: 1.day.from_now), "no height read, no release"
    assert allowed?(entry, height: 501), "CONTROL: one block past it"
  end

  test "a status that shows the wire, landed or merely seen, forbids a release at any height or age" do
    entry = submitted
    entry.record_payment_attempt!(signature: "sig-1", last_valid_block_height: 500)

    refute allowed?(entry, status: LANDED, height: 99_999, now: 1.day.from_now)
    refute allowed?(entry, status: { "err" => nil, "confirmationStatus" => "processed" }, height: 99_999, now: 1.day.from_now)
    assert allowed?(entry, status: FAILED, height: nil), "CONTROL: a wire that landed and failed cannot pay"
    refute allowed?(entry, status: FAILED.merge("confirmationStatus" => "processed"), height: 99_999), "a failure not yet confirmed is not one"
  end

  test "a signed attempt with no recorded height is never released by a clock" do
    entry = submitted
    entry.record_payment_attempt!(signature: "sig-1")

    refute allowed?(entry, height: 99_999, now: 1.year.from_now)
  end

  test "a Phantom wire also needs the wall-clock floor: its stored height does not bind the wire the wallet returned" do
    entry = pinned
    entry.begin_phantom_charge!(signature: "sig-1", wallet: @wallet, last_valid_block_height: 500)

    refute allowed?(entry, height: 99_999, now: 4.minutes.from_now), "past the height, inside the floor"
    refute allowed?(entry, height: 500, now: 6.minutes.from_now), "past the floor, at the height"
    assert allowed?(entry, height: 501, now: 6.minutes.from_now), "CONTROL: past both"

    entry.update_columns(payment_submitted_at: nil)
    refute allowed?(entry, height: 99_999, now: 1.year.from_now), "a stamp with no time is never released by a clock"
  end

  test "CONTROL: the floor is the Phantom rail's; a managed wire's height binds it" do
    entry = submitted
    entry.record_payment_attempt!(signature: "sig-1", last_valid_block_height: 500)

    assert allowed?(entry, height: 501, now: 1.second.from_now)
  end

  test "the landed sentence names the support contact the app uses elsewhere" do
    assert_includes Entry::Payment::IN_FLIGHT_MESSAGES.fetch("landed"), "contact support@turfmonster.media"
    assert_includes FrozenAccount::MESSAGE, Entry::Payment::SUPPORT_EMAIL
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

  # --- a payment that begins after the row was loaded ---------------------------

  test "a stamp that lands after clear_picks loaded the cart keeps the cart, its slot and the in-flight key" do
    entry = pinned
    loaded = Entry.find(entry.id) # what the clear request holds
    submitted(Entry.find(entry.id)).record_payment_attempt!(signature: "racing-sig", last_valid_block_height: 1_150)

    assert_equal false, loaded.abandon_draft_cart!
    assert_equal ["cart", "submitted", 0, "racing-sig"],
                 entry.reload.values_at(:status, :payment_state, :entry_number, :payment_signature)
  end

  test "a cart confirmed after it was loaded is not abandoned" do
    entry = pinned
    loaded = Entry.find(entry.id)
    entry.update!(status: :active)

    assert_equal false, loaded.abandon_draft_cart!
    assert_equal %w[active confirmed], entry.reload.values_at(:status, :payment_state)
  end

  test "CONTROL: a draft cart clears and gives up its slot; one carrying an on-chain signature keeps it" do
    plain = pinned
    assert_equal true, plain.abandon_draft_cart!
    assert_equal ["abandoned", "draft", nil], plain.reload.values_at(:status, :payment_state, :entry_number)
    assert_equal true, plain.abandon_draft_cart!, "clearing twice is still cleared"

    signed = pinned
    signed.update_columns(onchain_tx_signature: "landed-sig")
    assert_equal true, signed.abandon_draft_cart!
    assert_equal ["abandoned", 0], signed.reload.values_at(:status, :entry_number)
  end

  test "a row deleted from a copy loaded before its payment began stays" do
    entry = pinned
    loaded = Entry.find(entry.id) # a pick tap or a logout holding the draft
    submitted(Entry.find(entry.id))

    assert_raises(ActiveRecord::RecordNotDestroyed) { loaded.destroy! }
    assert_equal ["submitted", 6], [entry.reload.payment_state, entry.selections.count]
  end

  test "CONTROL: a draft cart is deleted, and an operator's reset still takes an in-flight row" do
    draft = cart
    draft.destroy!
    held = submitted
    Entry.lifting_payment_guard { held.destroy! }

    assert_empty Entry.where(id: [draft.id, held.id])
  end

  # --- adopt_found_ticket!: a draft pinned to the ticket the chain shows ----------

  test "a draft cart with no pin is pinned to the found ticket, and a cleared draft becomes a cart again" do
    entry = cart
    assert entry.adopt_found_ticket!(wallet: @wallet, slot: 2)
    assert_equal ["cart", "draft", @wallet, 2], entry.reload.values_at(:status, :payment_state, :wallet_address, :entry_number)

    other = make_managed!(users(:alex))
    cleared = cart(user: other)
    cleared.update!(status: :abandoned)
    assert cleared.adopt_found_ticket!(wallet: other.web2_solana_address, slot: 0)
    assert_equal ["cart", other.web2_solana_address, 0], cleared.reload.values_at(:status, :wallet_address, :entry_number)
  end

  test "adopt never touches a payment in flight, a live entry, or a row another session moved on" do
    in_flight = submitted
    stale = Entry.find(in_flight.id)
    assert_not stale.adopt_found_ticket!(wallet: @wallet, slot: 3), "a submitted row keeps its pin"
    assert_equal 0, in_flight.reload.entry_number

    other = make_managed!(users(:alex))
    racing = cart(user: other)
    loaded = Entry.find(racing.id) # read before the other session's payment begins
    on_chain(@vault) { racing.pin_payment_slot!(other.web2_solana_address, @vault) }
    racing.begin_charge!(rail: "managed")
    assert_not loaded.adopt_found_ticket!(wallet: other.web2_solana_address, slot: 4), "the row is re-read under its lock"
    assert_equal ["submitted", 0], racing.reload.values_at(:payment_state, :entry_number)

    racing.update_columns(status: "active", payment_state: "confirmed")
    assert_not Entry.find(racing.id).adopt_found_ticket!(wallet: other.web2_solana_address, slot: 4)
  end

  test "adopt never moves a pin: another wallet or another slot on the row refuses" do
    entry = pinned
    assert_not entry.adopt_found_ticket!(wallet: "OtherWallet#{SecureRandom.hex(4)}", slot: 0)
    assert_not entry.adopt_found_ticket!(wallet: @wallet, slot: 1)
    assert_equal [@wallet, 0], entry.reload.values_at(:wallet_address, :entry_number)
    assert entry.adopt_found_ticket!(wallet: @wallet, slot: 0), "CONTROL: the row's own pin is a no-op"
  end

  test "adopt answers false when another live row of the player holds the slot" do
    pinned # holds slot 0
    second = cart
    assert_not second.adopt_found_ticket!(wallet: @wallet, slot: 0)
    assert_equal ["cart", nil, nil], second.reload.values_at(:status, :wallet_address, :entry_number)
  end
end
