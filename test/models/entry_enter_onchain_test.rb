require "test_helper"

# [unit] Entry#enter_onchain!, the server-signed send behind a comped fill
# (Contest#fill!), pays at THE PIN: the managed wallet and one slot, fixed
# before the first send and reused by every later call. LedgerVault is the
# chain: a ticket exists there if and only if a payment landed.
class EntryEnterOnchainTest < ActiveSupport::TestCase
  include AgentApiTestSupport

  setup do
    @contest = make_onchain!(contests(:one))
    @user = make_managed!(users(:sam))
    @vault = LedgerVault.new
    @entry = @contest.entries.create!(user: @user, status: :cart)
    fixture_matchups.each { |matchup| @entry.selections.create!(slate_matchup: matchup) }
  end

  def fill = on_chain(@vault) { @entry.confirm!(comped: true) }
  def resend = on_chain(@vault) { @entry.reload.enter_onchain! }

  test "the wallet and slot are pinned before the send, to the wallet whose keypair signs" do
    @user.update!(web3_solana_address: "Phantom#{SecureRandom.hex(6)}") # a combo account: solana_address is the web3 one
    pinned = nil
    @vault.before_enter = -> { pinned = @entry.reload.values_at(:wallet_address, :entry_number) }

    fill

    assert_equal [@user.web2_solana_address, 0], pinned, "the pin is committed before the vault is called"
    assert_equal @user.web2_solana_address, @vault.enter_calls.sole[:wallet], "the managed keypair pays from the managed wallet"
    assert_equal @vault.tickets.sole[:signature], @entry.reload.onchain_tx_signature
    assert_equal @vault.tickets.sole[:pda], @entry.onchain_entry_id
  end

  test "a send that landed and lost its confirmation is not sent again: the pinned ticket is read first" do
    @vault.fail_next_enter = :lost
    fill
    assert_nil @entry.reload.onchain_tx_signature, "CONTROL: the first call never learned its send landed"
    assert_equal 1, @vault.tickets.size

    resend

    assert_equal 1, @vault.enter_calls.size, "nothing is sent while the pinned ticket exists"
    assert_equal 1, @vault.tickets.size, "exactly one payment is on chain"
    assert_equal [0, @vault.tickets.sole[:signature]], @entry.reload.values_at(:entry_number, :onchain_tx_signature)
  end

  test "CONTROL: a send that never landed is sent again at the same pin and pays once" do
    @vault.fail_next_enter = :unlanded
    fill
    assert_empty @vault.tickets

    resend

    assert_equal [0, 0], @vault.enter_calls.pluck(:entry_number), "the retry reuses the pinned slot"
    assert_equal 1, @vault.tickets.size
    assert_equal @vault.tickets.sole[:signature], @entry.reload.onchain_tx_signature
  end

  test "a chain that cannot be read sends nothing" do
    @vault.chain_unreadable = true

    fill

    assert_empty @vault.enter_calls, "an unreadable ticket is not an absent one"
    assert @entry.reload.active?, "the comped entry stands; only its chain call waits"
  end

  test "a ticket visible only at confirmed is on its way: nothing is sent" do
    @vault.fail_next_enter = :lost
    fill
    pda = @vault.tickets.sole[:pda]
    ticket = @vault.client.get_account_info(pda)
    @vault.instance_variable_get(:@ledger_accounts)[pda] = ->(commitment) { commitment == "finalized" ? nil : ticket }

    resend

    assert_equal 1, @vault.enter_calls.size
    assert_nil @entry.reload.onchain_tx_signature, "not yet final, so not yet recorded"
  end
end
