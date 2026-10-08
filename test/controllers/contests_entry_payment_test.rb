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
end
