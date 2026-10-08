require "test_helper"

# [integration] The managed rail through Entry::Payment, one test per way a
# payment goes wrong (the owner's list), each with its control. The standard
# held throughout: the player ends in a state they can act on, the picks
# survive, and trying again can never pay twice. LedgerVault is the chain: a
# ticket exists there if and only if a payment landed.
class Entries::ManagedEntryPaymentTest < ActiveSupport::TestCase
  include AgentApiTestSupport
  include ActiveJob::TestHelper

  setup do
    @contest = make_onchain!(contests(:one))
    @user = make_managed!(users(:sam))
    @vault = LedgerVault.new(tokens: [], usdc: 100.0)
    @entry = @contest.entries.create!(user: @user, status: :cart)
    fixture_matchups.each { |matchup| @entry.selections.create!(slate_matchup: matchup) }
  end

  def attempt(entry = @entry)
    on_chain(@vault) { Entries::ManagedEntry.new(contest: @contest, user: @user, usdc_allowed: true).call(entry) }
  end

  def settle(entry = @entry, now: Time.current)
    on_chain(@vault) { Entries::PaymentSettlement.call(entry, vault: @vault, now: now) }
  end

  def state = @entry.reload.values_at(:payment_state, :payment_refusal_code)
  def paid_once! = assert_equal(1, @vault.tickets.size, "exactly one payment is on chain")
  def picks_kept! = assert_equal(6, @entry.selections.count, "the picks survive")

  test "CONTROL: a clean attempt pays once, confirms, and records its signature before the send" do
    recorded = nil
    @vault.before_enter = -> { recorded = @entry.reload.values_at(:payment_state, :payment_signature) }
    outcome = attempt

    assert_equal ["submitted", nil], recorded, "the row is submitted, committed, before the vault is called"
    assert outcome.entry.active?
    assert_equal ["confirmed", nil], state
    assert_equal @vault.tickets.sole[:signature], @entry.payment_signature
    assert_equal 1_150, @entry.payment_last_valid_block_height
    paid_once!
  end

  test "RPC down before the send: nothing sent, cart back to draft, the retry pays once" do
    @vault.block_height = nil
    assert_raises(Solana::Client::RpcError) { attempt }

    assert_equal %w[draft rpc_unreachable], state
    assert_empty @vault.tickets
    assert_nil @entry.payment_signature
    picks_kept!

    @vault.block_height = 1_000
    assert attempt.entry.active?
    paid_once!
  end

  test "RPC down after the send, and it landed: pending, then the chain confirms it; a retry cannot pay again" do
    @vault.fail_next_enter = :lost
    @vault.chain_unreadable = true
    assert_enqueued_with(job: Entries::PaymentSettleJob, args: [@entry.id]) do
      assert_raises(Entries::ManagedEntry::PendingConfirmation) { attempt }
    end
    assert_equal ["submitted", nil], state
    assert @entry.payment_signature.present?, "the signature was committed before the send"
    assert_raises(Entry::Payment::InFlight) { attempt }
    paid_once!

    @vault.chain_unreadable = false
    assert settle.confirmed?
    assert @entry.reload.active?
    assert_equal @vault.tickets.sole[:signature], @entry.onchain_tx_signature
    paid_once!
  end

  test "RPC down after the send, and it never landed: pending until the wire lapses, then a draft cart that pays once" do
    @vault.fail_next_enter = :unlanded
    assert_raises(Entries::ManagedEntry::PendingConfirmation) { attempt }
    assert settle.pending?, "CONTROL: inside the wire's life the row is left alone"
    assert_equal ["submitted", nil], state

    @vault.block_height = 1_151
    assert settle.released?
    assert_equal %w[draft expired], state
    picks_kept!
    assert_equal 0, @entry.entry_number, "the slot stays pinned for the retry"

    assert attempt.entry.active?
    paid_once!
    assert_equal 0, @vault.tickets.sole[:slot]
  end

  # A SIGNED attempt is never released from what an error says. The text is
  # kept as the reason; the chain (the wire's last valid block height, then a
  # status and a ticket read made after it) is what releases the row.
  def assert_released_by_the_chain_only(code)
    assert_equal ["submitted", code], state, "the error's reading is a hint on a row still submitted"
    assert settle.pending?, "CONTROL: inside the wire's life nothing releases it"
    @vault.block_height = 1_151
    assert settle.released?
    assert_equal ["draft", code], state
    assert_empty @vault.tickets
    picks_kept!
  end

  test "the house wallet cannot pay the fee: pending, then released from the chain with the cause that is ours" do
    @vault.fail_next_enter = :fee
    assert_difference -> { ErrorLog.count }, 1, "the operator is told: the house wallet is short" do
      assert_raises(Entries::ManagedEntry::PendingConfirmation) { attempt }
    end
    assert_released_by_the_chain_only "network_fee"

    assert attempt.entry.active?
    paid_once!
  end

  test "not enough USDC, confirmed by a fresh read: refused before anything is signed, draft at once" do
    @vault = LedgerVault.new(tokens: [], usdc: 0.0)
    assert_equal :insufficient_funds, assert_raises(Entry::Refusal) { attempt }.code

    assert_equal %w[draft insufficient_funds], state
    assert_nil @entry.payment_signature, "nothing was signed, so nothing waits on the chain"
  end

  test "0x1 when the balance could not be read names both causes; 0x1 after a balance read as enough is ours" do
    @vault = LedgerVault.new(tokens: [], usdc: 0.0)
    @vault.wallet_balances_raises = true # the read flakes; the chain answers 0x1
    assert_raises(Entries::ManagedEntry::PendingConfirmation) { attempt }
    assert_released_by_the_chain_only "funds_or_fee"

    error = Solana::Client::RpcError.new("Transaction simulation failed: Error processing Instruction 0: custom program error: 0x1")
    code = ->(**context) { Entries::PaymentCopy.code_for(error, sent: true, **context) }
    assert_equal :network_fee, code.call(funding: "usdc", funds_confirmed: true), "the player's USDC was just read as enough"
    assert_equal :network_fee, code.call(funding: "token"), "a token entry moves no USDC at all"
    assert_equal :funds_or_fee, code.call(funding: "usdc", funds_confirmed: false)
    refute_match(/not enough USDC/i, Entries::PaymentCopy.message(:network_fee))
    assert_match(/on our side.*not charged/i, Entries::PaymentCopy.message(:network_fee))
  end

  test "the program refuses the entry in simulation (contest full): pending, then released with the reason" do
    @vault.fail_next_enter = :rejected
    assert_raises(Entries::ManagedEntry::PendingConfirmation) { attempt }
    assert_released_by_the_chain_only "contest_full"
  end

  test "a wire the cluster processed and failed is released at once: its status shows the error" do
    @vault.fail_next_enter = :landed_failed
    error = assert_raises(Solana::Client::RpcError) { attempt }

    assert_match(/Custom"=>6004/, error.message)
    assert_equal %w[draft contest_full], state, "read from the decimal shape, not shown as a bare refusal"
    assert_empty @vault.tickets
  end

  test "the status is read again after the height: a wire that lands late is confirmed, not released" do
    @vault.fail_next_enter = :unlanded
    assert_raises(Entries::ManagedEntry::PendingConfirmation) { attempt }
    @vault.block_height = 1_151
    signature = @entry.reload.payment_signature
    reads = 0
    # Unseen on the first read; landed by the read made after the height.
    @vault.instance_variable_get(:@ledger_statuses)[signature] =
      ->(_count) { (reads += 1) == 1 ? nil : { "err" => nil, "confirmationStatus" => "finalized" } }

    @vault.client.instance_variable_get(:@block_height_calls).clear
    assert settle.confirmed?
    assert_equal 2, reads, "one read before the height and one after"
    assert_equal ["finalized"], @vault.client.instance_variable_get(:@block_height_calls).uniq
    assert @entry.reload.active?
  end

  test "every ticket read asks for finalized, never the RPC's default" do
    @vault.fail_next_enter = :unlanded
    assert_raises(Entries::ManagedEntry::PendingConfirmation) { attempt }
    @vault.client.account_info_commitments.clear
    @vault.block_height = 1_151
    settle

    assert_equal ["finalized"], @vault.client.account_info_commitments.uniq
    assert_operator @vault.client.account_info_commitments.size, :>=, 2, "before the height and again after it"
  end

  test "the contest locks between the send and the confirm: the chain took it in time, so the entry stands" do
    @vault.fail_next_enter = :lost
    @vault.chain_unreadable = true
    assert_raises(Entries::ManagedEntry::PendingConfirmation) { attempt }

    travel 1.minute do
      @contest.update!(starts_at: 30.seconds.ago) # locked after the send, before anyone could confirm
      assert_raises(Entry::Refusal, "CONTROL: the contest is locked to a new entry") { @entry.reload.assert_enterable! }

      @vault.chain_unreadable = false
      assert settle.confirmed?
      assert @entry.reload.active?
      paid_once!
    end
  end

  test "paid, then refused by an app gate: landed, never released, and it blocks the next entry" do
    @vault.fail_next_enter = :lost
    @vault.chain_unreadable = true
    assert_raises(Entries::ManagedEntry::PendingConfirmation) { attempt }
    @contest.update!(max_entries: 1)
    enter!(users(:jordan), @contest, fixture_matchups) # the last seat goes to someone else

    @vault.chain_unreadable = false
    @vault.block_height = 9_999
    assert_difference -> { ErrorLog.where(target: @entry).count }, 1 do
      assert settle.landed?
      assert settle(now: 1.day.from_now).landed?, "a day later and far past the wire's life it is still landed"
    end
    assert_equal %w[landed contest_full], state
    assert @entry.cart?

    second = @contest.entries.new(user: @user, status: :cart)
    assert_raises(Entry::Payment::InFlight) { @entry.toggle_selection!(fixture_matchups.first) }
    assert_equal @entry, Entry.payment_in_flight_for(user: @user, contest: @contest)
    refute second.persisted?
  end

  test "a dyno dies mid-wait: the row it left is confirmed from the chain, or released when nothing was sent" do
    @vault.fail_next_enter = :lost
    @vault.chain_unreadable = true
    assert_raises(Entries::ManagedEntry::PendingConfirmation) { attempt } # the request never answered
    @vault.chain_unreadable = false
    travel 2.minutes do
      assert_equal 1, on_chain(@vault) { Entries::PaymentSweepJob.perform_now }[:confirmed]
    end
    assert @entry.reload.active?
    paid_once!

    unsent = @contest.entries.create!(user: make_managed!(users(:jordan)), status: :cart)
    on_chain(@vault) { unsent.pin_payment_slot!(unsent.user.web2_solana_address, @vault) }
    unsent.begin_charge!(rail: "managed") # died after this, before signing
    assert settle(unsent).pending?, "CONTROL: inside the grace a live request may still be about to send"
    assert settle(unsent, now: 31.seconds.from_now).released?
    assert_equal %w[draft not_sent], unsent.reload.values_at(:payment_state, :payment_refusal_code)
  end

  test "a retry of a cart whose first payment landed finds the ticket, confirms, and does not pay again" do
    on_chain(@vault) { @entry.pin_payment_slot!(@user.web2_solana_address, @vault) }
    @vault.send(:land!, @user.web2_solana_address, @contest.slug, 0, :usdc) { nil } # landed; the app never learned
    assert_equal "draft", @entry.reload.payment_state

    outcome = attempt # the program answers "already in use"

    assert outcome.entry.active?
    assert_equal @vault.tickets.sole[:signature], outcome.entry.onchain_tx_signature
    assert_equal 100.0, @vault.usdc_balance, "the retry moved no money"
    paid_once!
  end

  # --- the pinned ticket is read first, on every retry ------------------------------

  # The first payment landed and spent the wallet's only funds; the app never
  # learned (the row is a pinned draft).
  def landed_unseen!(vault)
    on_chain(vault) { @entry.pin_payment_slot!(@user.web2_solana_address, vault) }
    vault.send(:land!, @user.web2_solana_address, @contest.slug, 0, :usdc) { vault.wallet_balances = { sol: 0.1, usdc: 0.0, usdt: 0.0 } }
    assert_equal "draft", @entry.reload.payment_state
  end

  test "a retry whose first payment spent the funds is confirmed from its ticket, before any funding check" do
    @vault = LedgerVault.new(tokens: [], usdc: 19.0)
    landed_unseen!(@vault)
    @vault.client.account_info_commitments.clear

    service = Entries::ManagedEntry.new(contest: @contest, user: @user, usdc_allowed: true)
    outcome = on_chain(@vault) { service.call(@entry) }

    assert outcome.entry.active?
    assert service.first_payment_found?
    assert_equal @vault.tickets.sole[:signature], outcome.entry.onchain_tx_signature
    assert_empty @vault.enter_calls, "nothing was built or sent"
    assert_empty @vault.balance_calls, "the funding check never ran: it would have refused a wallet the first payment emptied"
    assert_equal ["finalized"], @vault.client.account_info_commitments.uniq
    paid_once!
  end

  test "CONTROL: the same emptied wallet with NO ticket is refused as unfunded, and a funded one pays once" do
    @vault = LedgerVault.new(tokens: [], usdc: 0.0)
    on_chain(@vault) { @entry.pin_payment_slot!(@user.web2_solana_address, @vault) }
    assert_equal :insufficient_funds, assert_raises(Entry::Refusal) { attempt }.code
    assert_empty @vault.tickets

    @vault.wallet_balances = { sol: 0.1, usdc: 100.0, usdt: 0.0 }
    assert attempt.entry.active?
    paid_once!
  end

  test "a pinned cart whose ticket cannot be read is not charged on a guess" do
    on_chain(@vault) { @entry.pin_payment_slot!(@user.web2_solana_address, @vault) }
    @vault.chain_unreadable = true

    assert_raises(Solana::Client::RpcError) { attempt }
    assert_empty @vault.enter_calls
    assert_equal "draft", @entry.reload.payment_state
  end

  test "two devices, two wallets: a Phantom payment in flight refuses the managed spend, and nothing is sent" do
    @user.update!(web3_solana_address: "PhantomWallet")
    on_chain(@vault) { @entry.pin_payment_slot!("PhantomWallet", @vault) }
    @entry.begin_charge!(rail: "phantom")

    error = assert_raises(Entry::Payment::InFlight) { attempt }
    assert_equal :payment_in_flight, error.code
    assert_empty @vault.enter_calls
    assert_equal "PhantomWallet", @entry.reload.wallet_address
  end

  test "CONTROL: the same two-wallet account with nothing in flight enters from its managed wallet" do
    @user.update!(web3_solana_address: "PhantomWallet")
    assert attempt.entry.active?
    assert_equal @user.web2_solana_address, @entry.reload.wallet_address
    paid_once!
  end

  test "lamports sent to the ticket address are not a ticket" do
    @vault.fail_next_enter = :unlanded
    assert_raises(Entries::ManagedEntry::PendingConfirmation) { attempt }
    pda = on_chain(@vault) { @entry.reload.payment_entry_pda(@vault) }
    refute @vault.client.get_account_info(pda), "CONTROL: the address is empty before the dust arrives"
    @vault.instance_variable_get(:@ledger_accounts)[pda] = { "value" => { "lamports" => 5_000, "owner" => "11111111111111111111111111111111" } }
    @vault.instance_variable_get(:@ledger_signatures)[pda] = [{ "signature" => "dust-transfer", "err" => nil }]

    assert @vault.client.get_account_info(pda), "CONTROL: the address now answers a read"
    assert settle.pending?
    refute @entry.reload.active?, "a transfer of dust to the address must never read as a paid entry"
  end
end
