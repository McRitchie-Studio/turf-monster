require "test_helper"

# [integration] Entries::PaymentSweepJob: the player who never came back.
class Entries::PaymentSweepJobTest < ActiveJob::TestCase
  include AgentApiTestSupport

  setup do
    @contest = make_onchain!(contests(:one))
    @vault = LedgerVault.new(tokens: [], usdc: 100.0)
  end

  # A cart whose payment was sent `ago`, with a wire good to block 1,150.
  def stamped(user, ago:, landed: false)
    make_managed!(user).update!(web2_solana_address: "#{user.id}-managed") # the fake's ticket address reads the first four characters
    entry = @contest.entries.create!(user: user, status: :cart)
    fixture_matchups.each { |matchup| entry.selections.create!(slate_matchup: matchup) }
    on_chain(@vault) { entry.pin_payment_slot!(user.web2_solana_address, @vault) }
    entry.begin_charge!(rail: "managed")
    entry.record_payment_attempt!(signature: "sig-#{user.id}", last_valid_block_height: 1_150)
    entry.update_columns(payment_submitted_at: ago.ago)
    @vault.send(:land!, user.web2_solana_address, @contest.slug, entry.entry_number, :usdc) { nil } if landed
    entry
  end

  def sweep = on_chain(@vault) { Entries::PaymentSweepJob.perform_now }

  test "a stale row whose wire has lapsed returns to draft with its picks; one that landed is confirmed" do
    lapsed = stamped(users(:sam), ago: 5.minutes)
    paid = stamped(users(:jordan), ago: 5.minutes, landed: true)
    @vault.block_height = 1_151

    assert_equal({ released: 1, confirmed: 1 }, sweep.to_h)
    assert_equal ["draft", "expired", 6], [*lapsed.reload.values_at(:payment_state, :payment_refusal_code), lapsed.selections.count]
    assert paid.reload.active?
    assert_equal "confirmed", paid.payment_state
  end

  test "CONTROL: a fresh row, a row whose wire can still land, and an unreadable chain are all left submitted" do
    fresh = stamped(users(:sam), ago: 10.seconds)
    @vault.block_height = 1_151
    assert_empty sweep.to_h, "inside the settle-after window the request may still hold the row"
    assert_equal "submitted", fresh.reload.payment_state

    fresh.update_columns(payment_submitted_at: 5.minutes.ago)
    @vault.block_height = 1_150
    assert_equal({ pending: 1 }, sweep.to_h, "at the last valid block the wire can still land")

    @vault.block_height = 1_151
    @vault.chain_unreadable = true
    assert_equal({ pending: 1 }, sweep.to_h)
    assert_equal "submitted", fresh.reload.payment_state
  end

  test "a landed row is never swept" do
    held = stamped(users(:sam), ago: 2.days, landed: true)
    held.mark_payment_landed!(code: :contest_full)
    @vault.block_height = 99_999

    assert_empty sweep.to_h
    assert_equal "landed", held.reload.payment_state
  end

  test "the sweep reads and never sends, so a retried run is harmless" do
    stamped(users(:sam), ago: 5.minutes, landed: true)
    sweep
    sweep

    assert_empty @vault.enter_calls
    assert_empty @vault.client.sent_transactions
  end

  test "rows no clock will release are still settled, and are named in the log by count and slug every run" do
    undated = stamped(users(:sam), ago: 2.days)
    undated.update_columns(payment_last_valid_block_height: nil)
    unstamped = stamped(users(:jordan), ago: 2.days)
    unstamped.update_columns(payment_submitted_at: nil, payment_rail: "phantom")
    @vault.block_height = 99_999

    log = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    stats = begin
      sweep
    ensure
      Rails.logger = previous
    end

    assert_equal({ pending: 2, never_by_clock: 2 }, stats.to_h, "both were LOOKED at (a landed one would confirm); neither is released")
    assert_equal %w[submitted submitted], [undated, unstamped].map { |row| row.reload.payment_state }
    line = log.string.lines.grep(/\[entry-payment\]\[sweep\]/).last
    assert_includes line, "never_by_clock=2"
    assert_includes line, undated.slug
    assert_includes line, unstamped.slug
    assert undated.payment_long_pending?
    assert_match(/much longer than usual.*contact support@turfmonster.media/m, Entries::PaymentCopy.message(:pending_long))
  end

  test "CONTROL: a dated row inside its window is not on the never-by-clock list" do
    stamped(users(:sam), ago: 5.minutes)
    assert_empty Entry.payment_never_released_by_clock
    refute sweep.key?(:never_by_clock)
  end
end
