require "test_helper"

# [unit] THE TICKET'S CREATING SIGNATURE. Anyone can send lamports to a ticket
# address, before the entry or after it, and that transfer is a success in the
# address's history. Entries::PaymentSettlement names the transaction that
# created the ticket only when it carries the entry instruction, signed by the
# pinned wallet, writing the ticket.
class Entries::PaymentSettlementTest < ActiveSupport::TestCase
  include AgentApiTestSupport

  setup do
    @contest = make_onchain!(contests(:one))
    @user = make_managed!(users(:sam))
    @vault = LedgerVault.new(usdc: 100.0)
    @entry = @contest.entries.create!(user: @user, status: :cart, wallet_address: @user.web2_solana_address, entry_number: 0)
    fixture_matchups.each { |matchup| @entry.selections.create!(slate_matchup: matchup) }
    @pda = @vault.entry_pda(@contest.slug, @user.web2_solana_address, 0).first
  end

  def settle = on_chain(@vault) { Entries::PaymentSettlement.call(@entry, vault: @vault) }

  # A payment that landed and that the app never learned of: a pinned draft
  # cart with its ticket on chain and no signature on the row.
  def land_unrecorded!
    on_chain(@vault) { @vault.enter_contest_with_usdc(user: @user, contest: @contest, entry_num: 0) }
    @vault.tickets.sole[:signature]
  end

  test "CONTROL: with only the entry in the ticket's history, the entry is confirmed from it" do
    creating = land_unrecorded!

    assert settle.confirmed?
    assert_equal creating, @entry.reload.onchain_tx_signature
  end

  test "dust sent to the address before the entry is never the creating signature" do
    dust = @vault.dust!(@pda)
    creating = land_unrecorded!

    assert settle.confirmed?
    assert_equal creating, @entry.reload.onchain_tx_signature
    assert_not_equal dust, @entry.onchain_tx_signature
  end

  test "a history that shows only dust names no signature: the paid row waits, and nothing is recorded" do
    creating = land_unrecorded!
    history = @vault.instance_variable_get(:@ledger_signatures)
    history[@pda] = []
    dust = @vault.dust!(@pda) # the entry has scrolled out of the page the RPC returned

    result = settle

    assert result.pending?
    assert_equal :ticket_unsigned, result.code
    assert_equal ["cart", "draft", nil], @entry.reload.values_at(:status, :payment_state, :onchain_tx_signature)
    assert_not_equal creating, dust
  end

  test "a signature the RPC has no record of is not chosen, and is not read as absent" do
    creating = land_unrecorded!
    @vault.instance_variable_get(:@ledger_transactions)[creating] = nil # getTransaction answers null

    result = settle

    assert result.pending?, "an unreadable transaction is asked again, never guessed"
    assert @entry.reload.cart?
  end

  test "an entry instruction signed by another wallet does not create this ticket" do
    creating = land_unrecorded!
    @vault.instance_variable_get(:@ledger_transactions)[creating] =
      ChainFixtures.program_transaction("enter_contest", signer: "SomeoneElse#{SecureRandom.hex(4)}", account: @pda)

    assert settle.pending?
    assert_nil @entry.reload.onchain_tx_signature
  end
end
