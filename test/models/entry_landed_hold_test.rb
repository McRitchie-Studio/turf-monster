require "test_helper"

# [unit] Entry::LandedHold: the hold's deadline across both DST Sundays, the
# player's one answer, the operator's go, and what an answer lifts. The chain
# is LedgerVault: a ticket exists there if and only if a payment landed, so
# "one ticket" means nothing was paid again.
class EntryLandedHoldTest < ActiveSupport::TestCase
  include AgentApiTestSupport
  include ActiveJob::TestHelper

  ET = ActiveSupport::TimeZone["America/New_York"]

  def expires(from) = Entry.landed_hold_expires_at(from)

  # --- the hold ---------------------------------------------------------------

  test "the hold ends the first Sunday at 9:00 AM Eastern after the row landed" do
    assert_equal Time.utc(2026, 10, 11, 13), expires(ET.local(2026, 10, 7, 20)) # Wednesday night, EDT
    assert_equal ET.local(2026, 10, 11, 9), expires(ET.local(2026, 10, 11, 8, 59)), "landed on the Sunday before 9: that morning"
  end

  test "a row that lands at or after 9:00 on a Sunday holds until the next Sunday" do
    assert_equal ET.local(2026, 10, 18, 9), expires(ET.local(2026, 10, 11, 9))
    assert_equal ET.local(2026, 10, 18, 9), expires(ET.local(2026, 10, 11, 23, 30))
  end

  test "fall back (first Sunday of November): 9:00 EST, which is 14:00 UTC" do
    deadline = expires(Time.utc(2026, 10, 31, 12)) # Saturday, still EDT

    assert_equal Time.utc(2026, 11, 1, 14), deadline
    assert_equal 9, deadline.in_time_zone(ET).hour
    assert_equal "EST", deadline.in_time_zone(ET).zone
  end

  test "spring forward (second Sunday of March): 9:00 EDT, which is 13:00 UTC" do
    deadline = expires(Time.utc(2027, 3, 13, 12)) # Saturday, still EST

    assert_equal Time.utc(2027, 3, 14, 13), deadline
    assert_equal 9, deadline.in_time_zone(ET).hour
    assert_equal "EDT", deadline.in_time_zone(ET).zone
  end

  test "a row from before payment_landed_at reads its hold from the attempt" do
    entry = Entry.new(payment_submitted_at: ET.local(2026, 10, 7, 12))

    assert_equal ET.local(2026, 10, 11, 9), entry.landed_hold_expires_at
  end

  # --- a landed row -----------------------------------------------------------

  setup do
    @contest = make_onchain!(contests(:one))
    @user = make_managed!(users(:sam))
    @vault = LedgerVault.new(tokens: [], usdc: 100.0)
    @entry = @contest.entries.create!(user: @user, status: :cart)
    fixture_matchups.each { |matchup| @entry.selections.create!(slate_matchup: matchup) }
  end

  def settle = on_chain(@vault) { Entries::PaymentSettlement.call(@entry, vault: @vault) }
  def resolve = on_chain(@vault) { @entry.resolve_landed!(vault: @vault) }

  # Paid on chain, then the contest filled before the app could activate it.
  def land!
    @vault.fail_next_enter = :lost
    @vault.chain_unreadable = true
    assert_raises(Entries::ManagedEntry::PendingConfirmation) do
      on_chain(@vault) { Entries::ManagedEntry.new(contest: @contest, user: @user, usdc_allowed: true).call(@entry) }
    end
    @contest.update!(max_entries: 1)
    @seat = enter!(users(:jordan), @contest, fixture_matchups)
    @vault.chain_unreadable = false
    assert settle.landed?
    assert_equal %w[landed contest_full], @entry.reload.values_at(:payment_state, :payment_refusal_code)
    assert_not_nil @entry.payment_landed_at
  end

  test "CONTROL: an unanswered landed row stays landed on every settle" do
    land!

    assert settle.landed?
    assert_not @entry.landed_hold_authorized?
    assert_equal "landed", @entry.reload.payment_state
  end

  test "re-authorize keeps the entry: landed to confirmed, with no second payment" do
    land!
    @entry.answer_landed!("reauthorized")

    assert resolve.confirmed?
    assert_equal %w[active confirmed], @entry.reload.values_at(:status, :payment_state)
    assert_equal 1, @vault.tickets.size, "nothing was paid again"
    assert_equal @vault.tickets.sole[:signature], @entry.onchain_tx_signature
  end

  test "decline keeps the row landed and authorizes nothing" do
    land!
    @entry.answer_landed!("declined")

    assert resolve.landed?
    assert_equal %w[cart landed declined], @entry.reload.values_at(:status, :payment_state, :landed_answer)
    assert_raises(Entry::LandedHold::Refused) { @entry.authorize_landed_replacement!(users(:alex), now: 2.weeks.from_now) }
  end

  test "the player answers once, and only inside the hold" do
    land!
    deadline = @entry.landed_hold_expires_at

    assert_raises(Entry::LandedHold::Refused) { @entry.answer_landed!("reauthorized", now: deadline) }
    @entry.answer_landed!("declined", now: deadline - 1.minute)
    assert_raises(Entry::LandedHold::Refused) { @entry.answer_landed!("reauthorized", now: deadline - 1.minute) }
    assert_equal "declined", @entry.reload.landed_answer
  end

  test "operator replace moves the row off landed, after the hold" do
    land!
    operator = users(:alex)

    assert_raises(Entry::LandedHold::Refused, "inside the hold the player still decides") do
      @entry.authorize_landed_replacement!(operator, now: @entry.landed_hold_expires_at - 1.minute)
    end
    @entry.authorize_landed_replacement!(operator, now: @entry.landed_hold_expires_at)

    assert resolve.confirmed?
    assert_equal %w[active confirmed], @entry.reload.values_at(:status, :payment_state)
    assert_equal operator.id, @entry.landed_replaced_by_id
    assert_equal 1, @vault.tickets.size, "the replacement is this row's own ticket; nothing was paid again"
  end

  test "the operator may replace a re-authorized row the verdict still refuses, inside the hold" do
    land!
    @entry.answer_landed!("reauthorized")

    @entry.authorize_landed_replacement!(users(:alex))
    assert_not_nil @entry.reload.landed_replaced_at
  end

  test "an answer lifts only the counted gates: a duplicate lineup still refuses, and the row stays landed" do
    land!
    @seat.update!(user: @user) # the player already holds this exact lineup
    @contest.update!(max_entries: 5)
    @entry.answer_landed!("reauthorized")

    result = resolve

    assert result.landed?
    assert_equal :duplicate_lineup, result.code
    assert_equal %w[cart landed], @entry.reload.values_at(:status, :payment_state)
  end

  test "a resolve the chain cannot read is asked again by the settle job" do
    land!
    @entry.answer_landed!("reauthorized")
    @vault.chain_unreadable = true

    assert_enqueued_with(job: Entries::PaymentSettleJob, args: [@entry.id]) { assert resolve.pending? }
    assert_equal "landed", @entry.reload.payment_state
  end

  # --- a decline is final ---------------------------------------------------
  #
  # Each test declines, then opens the seat the row was refused for, so every
  # ordinary gate clears. Only the decline stands between the row and live.

  def decline_and_open_seat!
    land!
    @entry.answer_landed!("declined")
    @contest.update!(max_entries: 10)
  end

  def assert_still_declined
    assert_equal %w[cart landed declined], @entry.reload.values_at(:status, :payment_state, :landed_answer)
    assert_equal 1, @vault.tickets.size, "nothing was paid again"
    assert_equal 0, TransactionLog.where(source: @contest, user: @user).count, "no entry fee was booked"
  end

  test "a declined row stays landed on a settlement retry once its gates clear" do
    decline_and_open_seat!

    result = settle
    assert result.landed?
    assert_equal :landed_declined, result.code
    on_chain(@vault) { Entries::PaymentSettleJob.perform_now(@entry.id) }
    assert_still_declined
  end

  test "a declined row stays landed through the reconciler, stored proof and chain" do
    decline_and_open_seat!
    assert_predicate @entry.reload.onchain_tx_signature, :present?, "the managed rail stored its proof"

    assert_not_equal :reconciled, on_chain(@vault) { Entries::OnchainReconciler.reconcile_entry(@entry, vault: @vault) }
    @entry.update_columns(onchain_tx_signature: nil) # the no-proof path: the verdict reads the chain
    assert_not_equal :reconciled, on_chain(@vault) { Entries::OnchainReconciler.reconcile_entry(@entry, vault: @vault) }
    assert_still_declined
  end

  test "a verdict that loaded the row before the decline cannot activate it after" do
    land!
    @contest.update!(max_entries: 10)
    stale = Entry.find(@entry.id) # unanswered when the racer read it
    Entry.find(@entry.id).answer_landed!("declined")
    signature = @vault.tickets.sole[:signature]

    refusal = assert_raises(Entry::Refusal) { stale.confirm!(tx_signature: signature, onchain_entry_id: stale.onchain_entry_id, held: true) }
    assert_equal :landed_declined, refusal.code
    assert_raises(Entry::Refusal) { stale.confirm_onchain!(tx_signature: signature, entry_pda: stale.onchain_entry_id, held: true) }
    assert_still_declined
  end

  test "the prompt asks about unanswered rows inside the hold only" do
    land!

    assert_equal [@entry], Entry.landed_prompts_for(@user)
    assert_empty Entry.landed_prompts_for(@user, now: @entry.landed_hold_expires_at)
    assert_empty Entry.landed_prompts_for(users(:jordan))
    @entry.answer_landed!("declined")
    assert_empty Entry.landed_prompts_for(@user)
  end

  # --- the database's own check -------------------------------------------------

  # Pins entries_landed_answer_known as Postgres enforces it from db/schema.rb,
  # whichever deparse of the IN list the dump carries: the two answers and NULL
  # pass, anything else is refused below the model.
  test "the landed_answer check admits only reauthorized, declined or NULL" do
    entry = entries(:one)

    [nil, "reauthorized", "declined"].each do |answer|
      entry.update_columns(landed_answer: answer)
      assert_equal answer, entry.reload.landed_answer
    end

    assert_raises(ActiveRecord::StatementInvalid) { entry.update_columns(landed_answer: "accepted") }
  end
end
