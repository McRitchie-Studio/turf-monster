require "test_helper"

# PendingTransaction#entry_recovery_verdict — the one answer
# ContestsController#recover_pending_entry fails a row on
# (recovery-never-fails-landed-entries). Failing a row lifts prepare_entry's
# 409, so a wrong :never_landed is a second payment.
class PendingTransactionEntryRecoveryTest < ActiveSupport::TestCase
  DEADLINE = 1_000_000

  def ptx(age:)
    PendingTransaction.create!(tx_type: "enter_contest", serialized_tx: "stx", status: "submitted",
                               initiator_address: "Wallet#{SecureRandom.hex(3)}",
                               tx_signature: "sig-#{SecureRandom.hex(4)}", broadcast_at: age.ago)
  end

  def lapsed
    OnchainSendVerdict::BLOCKHASH_LAPSE + 1.minute
  end

  def client(statuses: {}, **opts)
    FakeSolanaClient.new(statuses, **opts)
  end

  test "a 429 on the status read is unreadable, never a verdict" do
    row = ptx(age: lapsed)
    c = client(status_raises: "HTTP 429 Too Many Requests", block_height: DEADLINE + 1)

    assert_equal :unreadable, row.entry_recovery_verdict(c, last_valid_block_height: DEADLINE)
    assert_empty c.block_height_calls
  end

  test "five minutes elapsed before blockhash expiry is ambiguous, not never_landed" do
    row = ptx(age: lapsed)

    assert_equal :ambiguous, row.entry_recovery_verdict(client(block_height: DEADLINE), last_valid_block_height: DEADLINE)
  end

  test "past the window and past the deadline, a re-read still empty is never_landed" do
    row = ptx(age: lapsed)
    c = client(block_height: DEADLINE + 1)

    assert_equal :never_landed, row.entry_recovery_verdict(c, last_valid_block_height: DEADLINE)
    assert_equal ["finalized"], c.block_height_calls
    assert_equal 2, c.status_calls.size
  end

  test "the re-read after the height wins when the wire turns up" do
    row = ptx(age: lapsed)
    statuses = { row.tx_signature => ->(nth) { nth == 1 ? nil : { "err" => nil, "confirmationStatus" => "confirmed" } } }

    assert_equal :landed, row.entry_recovery_verdict(client(statuses: statuses, block_height: DEADLINE + 1),
                                                     last_valid_block_height: DEADLINE)
  end

  test "no recorded deadline is ambiguous however old the broadcast" do
    row = ptx(age: 1.day)
    c = client(block_height: DEADLINE * 10)

    assert_equal :ambiguous, row.entry_recovery_verdict(c, last_valid_block_height: nil)
    assert_empty c.block_height_calls
  end

  test "a failed height read is unreadable" do
    row = ptx(age: lapsed)

    assert_equal :unreadable, row.entry_recovery_verdict(client, last_valid_block_height: DEADLINE)
  end

  test "inside the window the height is never read" do
    row = ptx(age: 30.seconds)
    c = client(block_height: DEADLINE + 1)

    assert_equal :ambiguous, row.entry_recovery_verdict(c, last_valid_block_height: DEADLINE)
    assert_empty c.block_height_calls
  end

  test "landed and failed statuses pass straight through" do
    row = ptx(age: 30.seconds)

    assert_equal :landed, row.entry_recovery_verdict(
      client(statuses: { row.tx_signature => { "err" => nil, "confirmationStatus" => "finalized" } }),
      last_valid_block_height: DEADLINE)
    assert_equal :failed, row.entry_recovery_verdict(
      client(statuses: { row.tx_signature => { "err" => { "InstructionError" => [0, "x"] }, "confirmationStatus" => "confirmed" } }),
      last_valid_block_height: DEADLINE)
  end
end
