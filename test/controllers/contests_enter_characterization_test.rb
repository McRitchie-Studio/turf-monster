require "test_helper"
require "minitest/mock"

# CHARACTERIZATION of POST /contests/:slug/enter, the browser's managed-wallet
# entry. Written against the controller BEFORE its funding path was extracted
# into Entries::ManagedEntry (task agent-api-entry-endpoints) and green on both
# sides of that extraction: the agent API now calls the same service, and the
# browser's contract must not have moved by a byte.
#
# contests_controller_test.rb asserts each branch's behaviour. This file pins
# the parts those tests read loosely: the exact JSON shapes, the order of the
# chain calls, and the rows written.
class ContestsEnterCharacterizationTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @contest = contests(:one)
    @user = users(:sam)
    @user.update!(web3_solana_address: nil,
                  web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
                  encrypted_web2_solana_private_key: "ciphertext")
    @contest.update!(onchain_contest_id: "onchain-char", season_id: 1)
    SeasonConfig.set_current!(1)
    log_in_as @user
    @entry = @contest.entries.create!(user: @user, status: :cart)
    %i[m1 m2 m3 m4 m5 m6].each { |name| @entry.selections.create!(slate_matchup: slate_matchups(name)) }
  end

  def enter_with(vault, usdc_entry: false)
    AppFlags.stub :web2_usdc_entry?, usdc_entry do
      Solana::Keypair.stub :from_encrypted, "fake-keypair-object" do
        Solana::Vault.stub :new, vault do
          post enter_contest_path(@contest), as: :json
        end
      end
    end
  end

  test "token entry: exact success body, rows written, and chain call order" do
    vault = FakeVault.new(tokens: [{ pda: "tpda_1", consumed: false }])
    vault.sync_balance_seeds = 75

    assert_difference -> { TransactionLog.where(user: @user, transaction_type: "entry_fee").count }, 1 do
      enter_with(vault)
    end

    assert_response :success
    @entry.reload
    body = JSON.parse(response.body)
    assert_equal %w[redirect seeds_earned seeds_level seeds_total success token_consumed tx_signature], body.keys.sort
    assert_equal true, body["success"]
    assert_equal contest_path(@contest), body["redirect"]
    assert_equal @entry.onchain_tx_signature, body["tx_signature"]
    assert_equal true, body["token_consumed"]
    assert_equal 25, body["seeds_earned"]
    assert_equal 75, body["seeds_total"]
    assert_equal User.level_for(75), body["seeds_level"]

    assert @entry.active?
    assert_equal 0, @entry.entry_number
    assert_match(/\Afake-enter-with-token-/, @entry.onchain_tx_signature)
    assert_match(/\Aepda-/, @entry.onchain_entry_id)

    call = vault.enter_calls.sole
    assert_equal({ method: :enter_contest_with_token, wallet: @user.web2_solana_address, slug: @contest.slug,
                   entry_number: 0, token_pda: "tpda_1", season_id: 1 }, call)
    assert_equal [{ wallet: @user.web2_solana_address, username: @user.username }], vault.ensure_account_calls
    assert_empty vault.balance_calls, "a token entry never reads a USDC balance"
  end

  test "usdc entry: exact success body and no token consume" do
    vault = FakeVault.new(tokens: [])
    vault.wallet_balances = { sol: 0.1, usdc: 25.0, usdt: 0.0 }

    enter_with(vault, usdc_entry: true)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal %w[redirect seeds_earned seeds_level seeds_total success token_consumed tx_signature], body.keys.sort
    assert_equal false, body["token_consumed"]
    assert_equal :enter_contest_with_usdc, vault.enter_calls.sole[:method]
    assert_equal [@user.web2_solana_address], vault.balance_calls
    assert @entry.reload.active?
  end

  test "no funding: exact refusal body, nothing spent, entry stays cart, one error log on the entry" do
    vault = FakeVault.new(tokens: [])

    assert_difference -> { ErrorLog.where(target: @entry).count }, 1 do
      enter_with(vault)
    end

    assert_response :unprocessable_entity
    assert_equal({ "success" => false, "error" => "No entry tokens. Buy at /tokens/buy",
                   "blocker" => { "reason" => "no_funding", "mode" => "web2", "data" => {} } },
                 JSON.parse(response.body))
    assert_empty vault.enter_calls
    @entry.reload
    assert @entry.cart?
    assert_nil @entry.onchain_tx_signature
    assert_nil @entry.entry_number, "the slot assigned inside the contest lock rolls back with it"
    assert_equal @contest, ErrorLog.where(target: @entry).last.parent
  end

  test "underfunded usdc: exact refusal body with the fee it needed" do
    vault = FakeVault.new(tokens: [])
    vault.wallet_balances = { sol: 0.1, usdc: 1.0, usdt: 0.0 }

    enter_with(vault, usdc_entry: true)

    assert_response :unprocessable_entity
    assert_equal({ "success" => false, "error" => "Not enough USDC to enter. Top up your wallet and try again.",
                   "blocker" => { "reason" => "no_funding", "mode" => "web2",
                                  "data" => { "neededCents" => @contest.entry_fee_cents } } },
                 JSON.parse(response.body))
    assert_empty vault.enter_calls
  end

  test "a gate that fails is answered before any chain call, in the gate's own words" do
    @entry.selections.first.destroy!
    vault = FakeVault.new(tokens: [{ pda: "tpda_1", consumed: false }])

    enter_with(vault)

    assert_response :unprocessable_entity
    assert_equal({ "success" => false, "error" => "Exactly 6 selections required", "blocker" => nil },
                 JSON.parse(response.body))
    assert_empty vault.enter_calls
    assert_empty vault.entry_token_list_calls
  end

  test "no season configured: refused with the operator message, nothing spent" do
    SeasonConfig.set_current!(0)
    vault = FakeVault.new(tokens: [{ pda: "tpda_1", consumed: false }])

    enter_with(vault)

    assert_response :unprocessable_entity
    assert_match(/\ANo active season configured\./, JSON.parse(response.body)["error"])
    assert_empty vault.enter_calls
  ensure
    SeasonConfig.set_current!(1)
  end

  test "confirm fails after the spend: success body stands, proof is on the row, reconcile is queued" do
    vault = FakeVault.new(tokens: [{ pda: "tpda_1", consumed: false }])
    boom = ->(*, **) { raise StandardError, "simulated post-broadcast DB failure" }

    assert_enqueued_with(job: Entries::OnchainReconcileJob, args: [@entry.id]) do
      TransactionLog.stub :record!, boom do
        enter_with(vault)
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    @entry.reload
    assert_equal true, body["success"]
    assert_equal true, body["token_consumed"]
    assert_equal @entry.onchain_tx_signature, body["tx_signature"]
    assert @entry.cart?
    assert @entry.onchain_tx_signature.present?
    assert_equal 0, Message.where(contest: @contest, user: @user).count, "no join announcement until it is active"
  end
end
