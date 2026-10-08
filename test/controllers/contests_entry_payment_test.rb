require "test_helper"
require "minitest/mock"

# [integration] What the PAGE is told while a payment is unresolved, on both
# rails: a typed answer with a sentence, never a bare error and never a second
# charge. The chain is LedgerVault; a ticket exists there iff a payment landed.
class ContestsEntryPaymentTest < ActionDispatch::IntegrationTest
  include AgentApiTestSupport
  include ActiveJob::TestHelper

  setup do
    @contest = make_onchain!(contests(:one))
    @user = make_managed!(users(:sam))
    @vault = LedgerVault.new(tokens: [], usdc: 100.0)
    log_in_as @user
    @entry = @contest.entries.create!(user: @user, status: :cart)
    fixture_matchups.each { |matchup| @entry.selections.create!(slate_matchup: matchup) }
  end

  def chain(&block) = AppFlags.stub(:web2_usdc_entry?, true) { on_chain(@vault, &block) }
  def hold = chain { post enter_contest_path(@contest), as: :json }
  def poll = chain { post entry_payment_status_contest_path(@contest), params: { entry: @entry.slug }, as: :json }
  def body = JSON.parse(response.body)

  def assert_plain_sentence(text)
    assert_match(/\A[A-Z].+[.!]\z/m, text)
    refute_match(/0x|RpcError|simulation|Instruction|undefined|Exception|processing\.\.\./i, text, "no raw error reaches the player")
  end

  test "the request cannot wait for the confirm: 202 pending, a job finishes it, and the poll confirms once" do
    @vault.fail_next_enter = :lost
    @vault.chain_unreadable = true
    assert_enqueued_with(job: Entries::PaymentSettleJob, args: [@entry.id]) { hold }

    assert_response :accepted
    assert_equal ["entry_pending", @entry.slug, false, false], body.values_at("code", "entry", "success", "retry")
    assert_match(/still confirming.*not be charged twice/i, body["error"])
    assert_plain_sentence body["error"]

    poll
    assert_equal "pending", body["status"], "CONTROL: while the chain cannot be read the page is told to ask again"

    @vault.chain_unreadable = false
    poll
    assert_equal ["confirmed", contest_path(@contest)], body.values_at("status", "redirect")
    assert @entry.reload.active?
    assert_equal 1, @vault.tickets.size
  end

  test "a double click: the second hold is refused with the same sentence and sends nothing" do
    @vault.fail_next_enter = :unlanded
    hold
    assert_response :accepted
    hold

    assert_response :conflict
    assert_equal ["entry_pending", @entry.slug], body.values_at("code", "entry")
    assert_plain_sentence body["error"]
    assert_equal 1, @vault.enter_calls.size, "the second hold never reached the vault"
    assert_empty @vault.tickets
  end

  test "an attempt that never landed: the poll says so in a sentence, and the next hold pays once" do
    @vault.fail_next_enter = :unlanded
    hold
    @vault.block_height = 1_151
    poll

    assert_equal ["retry", "expired", true], body.values_at("status", "code", "retry")
    assert_match(/never reached Solana.*not charged.*picks are saved.*try again/i, body["error"])
    assert_equal 6, @entry.reload.selections.count

    hold
    assert_response :success
    assert body["success"]
    assert_equal 1, @vault.tickets.size
  end

  test "a hold after the first payment landed unseen answers success for that entry, charging nothing more" do
    @vault.fail_next_enter = :lost
    @vault.chain_unreadable = true
    hold
    @vault.chain_unreadable = false
    hold

    assert_response :success
    assert_equal true, body["success"]
    assert_match(/first payment went through.*not charged again/i, body["message"])
    assert_equal @vault.tickets.sole[:signature], body["tx_signature"]
    assert_equal 1, @vault.enter_calls.size
  end

  test "the network is down before anything is sent: a sentence, a safe retry, and no raw error" do
    @vault.block_height = nil
    hold

    assert_response :unprocessable_entity
    assert_equal ["rpc_unreachable", true], body.values_at("code", "retry")
    assert_match(/nothing was sent.*not charged.*try again/i, body["error"])
    assert_plain_sentence body["error"]
    assert_equal %w[draft rpc_unreachable], @entry.reload.values_at(:payment_state, :payment_refusal_code)
  end

  test "an older attempt's reason is not read back for a new failure" do
    @vault.fail_next_enter = :unlanded
    hold
    @vault.block_height = 1_151
    poll # the first attempt lapsed: the row now carries `expired`
    assert_equal "expired", @entry.reload.payment_refusal_code

    @vault.block_height = nil # and now the network is down before anything is sent
    hold
    assert_equal "rpc_unreachable", body["code"]
    assert_match(/nothing was sent/i, body["error"])
  end

  test "CONTROL: a contest rule keeps its own words and is not dressed as a network failure" do
    @entry.selections.last.destroy!
    hold

    assert_response :unprocessable_entity
    assert_equal "Exactly 6 selections required", body["error"]
    assert_nil body["code"]
  end

  test "picks cannot be edited, cleared or toggled away while their payment is unresolved" do
    @vault.fail_next_enter = :unlanded
    hold

    chain { post toggle_selection_contest_path(@contest), params: { matchup_id: fixture_matchups.first.id }, as: :json }
    assert_response :conflict
    assert_equal "entry_pending", body["code"]
    assert_plain_sentence body["error"]

    chain { post clear_picks_contest_path(@contest), as: :json }
    assert_response :conflict
    assert_equal ["submitted", "cart", 6], [*@entry.reload.values_at(:payment_state, :status), @entry.selections.count]
  end

  test "CONTROL: a draft cart toggles and clears, and so does one whose attempt has lapsed" do
    chain { post toggle_selection_contest_path(@contest), params: { matchup_id: fixture_matchups.first.id }, as: :json }
    assert_response :success
    assert_equal 5, body["selection_count"]

    @entry.selections.create!(slate_matchup: fixture_matchups.first)
    @vault.fail_next_enter = :unlanded
    hold
    @vault.block_height = 1_151
    chain { post clear_picks_contest_path(@contest), as: :json }
    assert_response :success
    assert @entry.reload.abandoned?
  end

  test "two devices, two wallets: a Phantom payment in flight refuses the managed hold (and the reverse)" do
    @user.update!(web3_solana_address: "PhantomTwoDevices")
    chain { @entry.pin_payment_slot!("PhantomTwoDevices", @vault) }
    @entry.begin_phantom_charge!(signature: "phantom-sig", wallet: "PhantomTwoDevices", last_valid_block_height: 1_150)

    hold # the same account, signed in with Google on another device
    assert_response :conflict
    assert_equal "entry_pending", body["code"]
    assert_empty @vault.enter_calls, "the managed wallet spent nothing"

    @entry.release_payment!(:expired)
    @vault.fail_next_enter = :unlanded
    hold # now the managed payment is the one in flight
    assert_response :accepted
    log_in_as_onchain(@user)
    chain { post prepare_entry_contest_path(@contest), as: :json }
    assert_response :conflict
    assert_equal "entry_pending", body["code"]
    assert_equal 0, PendingTransaction.where(target: @entry).count, "no second wire was built"
  end

  test "a paid entry an app gate refused is held: the page says so and the player cannot start another" do
    @vault.fail_next_enter = :lost
    @vault.chain_unreadable = true
    hold
    @contest.update!(max_entries: 1)
    enter!(users(:jordan), @contest, fixture_matchups)
    @vault.chain_unreadable = false

    poll
    assert_equal ["held", "landed", false], body.values_at("status", "code", "retry")
    assert_match(/payment.*arrived.*not be charged again/i, body["error"])

    hold
    assert_response :conflict
    assert_equal "entry_held", body["code"]
    assert_equal 1, @vault.enter_calls.size
  end

  # --- BLOCKER 1: the Phantom release is no weaker than the rule it replaced -------

  # A Phantom wire stamped and sent `ago`, built to land by block 1,150.
  def phantom_in_flight(ago: 0.seconds)
    log_in_as_onchain(@user)
    @wallet = @user.reload.web3_solana_address
    chain { @entry.pin_payment_slot!(@wallet, @vault) }
    @ptx = PendingTransaction.create!(tx_type: "enter_contest", serialized_tx: "stx", status: "submitted",
                                      tx_signature: "phantom-sig", broadcast_at: ago.ago, target: @entry,
                                      initiator_address: @wallet,
                                      metadata: { last_valid_block_height: 1_150 }.to_json)
    @entry.begin_phantom_charge!(signature: "phantom-sig", wallet: @wallet, last_valid_block_height: 1_150)
    @entry.update_columns(payment_submitted_at: ago.ago)
  end

  def recover
    chain do
      Solana::TxVerifier.stub(:verify!, true) { post recover_pending_entry_contest_path(@contest), params: { ptx_slug: @ptx.slug }, as: :json }
    end
  end

  test "Phantom: past the stored height but inside five minutes nothing is released, and the late wire is confirmed" do
    phantom_in_flight(ago: 2.minutes)
    @vault.block_height = 1_151 # the height the SERVER's wire could land by has passed

    recover
    assert_equal "processing", body["status"], "the wallet may have signed a fresher blockhash: the height does not bind it"
    assert_equal({ pending: 1 }, chain { Entries::PaymentSweepJob.perform_now }.to_h, "nor does the sweep release it")
    assert_equal %w[submitted submitted], [@entry.reload.payment_state, @ptx.reload.status]

    chain { post prepare_entry_contest_path(@contest), as: :json }
    assert_response :conflict, "and no second wire is built meanwhile"

    @vault.send(:land!, @wallet, @contest.slug, @entry.entry_number, :usdc) { nil } # it lands, late
    recover
    assert_equal "confirmed", body["status"]
    assert @entry.reload.active?
    assert_equal "confirmed", @ptx.reload.status
    assert_equal 1, @vault.tickets.size
  end

  test "CONTROL Phantom: past the height AND the five minutes, with no status and no ticket, the row is released" do
    phantom_in_flight(ago: 6.minutes)
    @vault.block_height = 1_150
    recover
    assert_equal "processing", body["status"], "past the clock alone is not enough either"

    @vault.block_height = 1_151
    @vault.client.account_info_commitments.clear
    recover
    assert_equal "failed", body["status"]
    assert_equal Entries::PaymentCopy.message(:expired), body["error"]
    assert_equal %w[draft expired failed], [*@entry.reload.values_at(:payment_state, :payment_refusal_code), @ptx.reload.status]
    assert_equal %w[finalized finalized confirmed], @vault.client.account_info_commitments, "never the RPC's default"
    assert_equal 6, @entry.selections.count
  end

  test "Phantom: a wire that failed on chain is released with its own sentence, not 'never reached Solana'" do
    phantom_in_flight
    @vault.instance_variable_get(:@ledger_statuses)["phantom-sig"] =
      { "err" => { "InstructionError" => [0, { "Custom" => 6004 }] }, "confirmationStatus" => "finalized" }

    recover
    assert_equal "failed", body["status"]
    assert_match(/reached Solana and was turned down there/, body["error"])
    assert_equal "failed_onchain", @entry.reload.payment_refusal_code
  end

  # --- BLOCKER 2: a pinned draft cart whose ticket exists is confirmed, not charged ---

  test "Phantom: prepare reads the pinned ticket first; when it exists the entry is confirmed and no wire is built" do
    log_in_as_onchain(@user)
    wallet = @user.reload.web3_solana_address
    chain { @entry.pin_payment_slot!(wallet, @vault) }
    @vault.send(:land!, wallet, @contest.slug, 0, :usdc) { nil } # landed; the row was (wrongly) left a draft
    assert_equal "draft", @entry.reload.payment_state

    assert_no_difference "PendingTransaction.count" do
      chain { Solana::TxVerifier.stub(:verify!, true) { post prepare_entry_contest_path(@contest), as: :json } }
    end

    assert_response :conflict
    assert_equal "entry_confirmed", body["code"]
    assert_match(/first payment went through.*not charged again/i, body["error"])
    assert_equal contest_path(@contest), body["redirect"]
    assert @entry.reload.active?
    assert_equal ["phantom", wallet], @entry.values_at(:payment_rail, :wallet_address)
    assert_equal 1, @vault.tickets.size
  end

  test "CONTROL Phantom: the same pinned cart with no ticket is handed a wire, at the same slot" do
    log_in_as_onchain(@user)
    wallet = @user.reload.web3_solana_address
    chain { @entry.pin_payment_slot!(wallet, @vault) }

    assert_difference "PendingTransaction.count", 1 do
      chain { post prepare_entry_contest_path(@contest), as: :json }
    end
    assert_response :success, response.body
    assert body["serialized_tx"].present?
    assert_equal [0, "draft"], @entry.reload.values_at(:entry_number, :payment_state)
  end

  test "clear picks cannot move a paid cart to a new slot: the ticket is read first and the entry confirmed" do
    chain { @entry.pin_payment_slot!(@user.web2_solana_address, @vault) }
    @vault.send(:land!, @user.web2_solana_address, @contest.slug, 0, :usdc) { nil }

    chain { post clear_picks_contest_path(@contest), as: :json }

    assert_response :conflict
    assert_equal "entry_confirmed", body["code"]
    assert @entry.reload.active?, "not abandoned: its slot would have been released and the next cart charged again"
  end

  test "clear picks on a pinned cart whose ticket cannot be read changes nothing" do
    chain { @entry.pin_payment_slot!(@user.web2_solana_address, @vault) }
    @vault.chain_unreadable = true

    chain { post clear_picks_contest_path(@contest), as: :json }

    assert_response :service_unavailable
    assert_equal "check_failed", body["code"]
    assert_match(/could not check your last payment.*nothing was changed/i, body["error"])
    assert @entry.reload.cart?
  end

  test "a pick tap reads the chain only for a cart that once sent a payment" do
    chain { @entry.pin_payment_slot!(@user.web2_solana_address, @vault) }
    @vault.client.account_info_commitments.clear
    chain { post toggle_selection_contest_path(@contest), params: { matchup_id: fixture_matchups.first.id }, as: :json }
    assert_response :success
    assert_empty @vault.client.account_info_commitments, "CONTROL: a cart that never sent anything costs no read"

    @entry.selections.create!(slate_matchup: fixture_matchups.first) # six picks again
    @entry.update_columns(payment_signature: "an-earlier-attempt")
    @vault.send(:land!, @user.web2_solana_address, @contest.slug, 0, :usdc) { nil }
    chain { post toggle_selection_contest_path(@contest), params: { matchup_id: fixture_matchups.second.id }, as: :json }
    assert_response :conflict
    assert_equal "entry_confirmed", body["code"]
  end

  # --- ROUND 2, B1: two rails, one cart; the pin never moves under a wire ------------

  def managed_hold_fails_before_sending
    @vault.block_height = nil
    assert_raises(Solana::Client::RpcError) do
      chain { Entries::ManagedEntry.new(contest: @contest, user: @user.reload, usdc_allowed: true).call(@entry.reload) }
    end
    @vault.block_height = 1_000
  end

  test "a combo account: a managed hold while a Phantom wire is prepared is refused, and does not re-pin the cart" do
    log_in_as_onchain(@user)
    phantom = @user.reload.web3_solana_address
    chain { post prepare_entry_contest_path(@contest), as: :json }
    assert_response :success, response.body
    assert_equal [phantom, 0], @entry.reload.values_at(:wallet_address, :entry_number)

    reset! # a second device: a new session
    log_in_as @user # the same account, signed in with Google
    hold

    assert_response :conflict
    assert_equal ["payment_started_elsewhere", true], body.values_at("code", "retry")
    assert_match(/started in another session.*not charged/, body["error"])
    assert_equal [:build_enter_contest], @vault.enter_calls.map { |call| call[:method] }, "only the Phantom build: the managed wallet sent nothing"
    assert_empty @vault.tickets
    assert_equal [phantom, 0, "draft"], @entry.reload.values_at(:wallet_address, :entry_number, :payment_state)
  end

  test "the old Phantom wire is refused at its send once the cart is pinned elsewhere: nothing goes out, nothing is released" do
    log_in_as_onchain(@user)
    phantom = @user.reload.web3_solana_address
    chain { post prepare_entry_contest_path(@contest), as: :json }
    wire = JSON.parse(response.body)

    travel 6.minutes do # the unsigned wire no longer holds the pin
      managed_hold_fails_before_sending
      assert_equal @user.web2_solana_address, @entry.reload.wallet_address, "CONTROL: the managed rail now holds the pin"

      chain do
        post confirm_onchain_entry_contest_path(@contest),
             params: { signed_tx: "PHANTOM_SIGNED_WIRE_B64", entry_id: @entry.id, entry_pda: wire["entry_pda"] }, as: :json
      end
    end

    assert_response :unprocessable_entity
    assert_equal ["pin_moved", true], body.values_at("code", "retry")
    assert_equal 0, @vault.cosign_broadcast_sends, "the wire that pays the OLD address was never sent"
    assert_equal ["draft", @user.web2_solana_address], @entry.reload.values_at(:payment_state, :wallet_address)
    refute_equal phantom, @entry.wallet_address, "the confirm did not flip the wallet back"
  end

  test "CONTROL: with the pin untouched the same Phantom wire is stamped and sent" do
    log_in_as_onchain(@user)
    chain { post prepare_entry_contest_path(@contest), as: :json }
    wire = JSON.parse(response.body)

    chain do
      Solana::TxVerifier.stub(:verify!, true) do
        post confirm_onchain_entry_contest_path(@contest),
             params: { signed_tx: "PHANTOM_SIGNED_WIRE_B64", entry_id: @entry.id, entry_pda: wire["entry_pda"] }, as: :json
      end
    end

    assert_equal 1, @vault.cosign_broadcast_sends
    assert_equal "phantom", @entry.reload.payment_rail
    refute_equal "draft", @entry.payment_state
  end

  # --- the funding pre-check sits in front of the hold ---------------------------------

  def funding = chain { post check_funding_contest_path(@contest), as: :json }

  test "the funding check never puts the funds panel in front of a cart that may already be paid for" do
    @vault = LedgerVault.new(tokens: [], usdc: 0.0) # the first payment spent everything
    funding
    assert_equal [false, "no_funding"], body.values_at("fundable", "reason"), "CONTROL: an empty wallet and a cart that never paid"

    chain { @entry.pin_payment_slot!(@user.web2_solana_address, @vault) }
    @entry.update_columns(payment_signature: "an-earlier-attempt")
    funding
    assert_equal [true, nil], body.values_at("fundable", "reason"), "a cart that once sent a payment is #enter's to answer"

    @entry.begin_charge!(rail: "managed")
    funding
    assert_equal true, body["fundable"], "and so is one with a payment in flight"
  end
end
