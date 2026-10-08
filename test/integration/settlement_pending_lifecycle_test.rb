require "test_helper"
require "minitest/mock"

# [integration] THE SETTLEMENT LIFECYCLE THROUGH THE DOORS AN OPERATOR USES.
#
# Grade (ContestsController#grade) leaves an on-chain contest
# settlement_pending and says so. A second grade is refused with a reason
# (422 for JSON, never a 500). A settle that fails on chain keeps the contest
# pending with the reason on the contest page and in the cosign queue, and the
# row can be rebuilt. The contest reads settled only once the cosigned settle
# is verified on chain (Admin::PendingTransactionsController#broadcast).
class SettlementPendingLifecycleTest < ActionDispatch::IntegrationTest
  include SettlementScenario
  include ActiveJob::TestHelper

  setup do
    @admin = users(:alex)
    @contest = settlement_contest(name: "Lifecycle")
    @winner = settlement_entry(@contest, score: 100.0)
    log_in_as(@admin)
  end

  test "grade answers with the pending notice and the contest page says the prizes are not paid yet" do
    grade

    assert_redirected_to contest_path(@contest)
    assert_match "Its settlement is pending: nothing is paid until", flash[:notice]
    assert_equal "settlement_pending", @contest.reload.status

    get contest_path(@contest)
    assert_response :success
    assert_select "[data-settlement-notice]", text: /Results are final\./
    assert_select "[data-settlement-notice]", text: /Settlement pending: the settle transaction is waiting/
  end

  test "control: an off-chain contest grades straight to settled and shows no pending notice" do
    @contest.update_columns(onchain_contest_id: nil)

    grade

    assert_equal "Contest graded and settled!", flash[:notice]
    assert_equal "settled", @contest.reload.status
    get contest_path(@contest)
    assert_select "[data-settlement-notice]", count: 0
  end

  test "a second grade is refused: 422 with the reason for JSON, an alert for the page, nothing regraded" do
    grade

    grade(as: :json)
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal false, body["success"]
    assert_equal Contest::Settlement::SETTLEMENT_PENDING_GRADE_MESSAGE, body["error"]

    grade
    assert_redirected_to contest_path(@contest)
    assert_equal Contest::Settlement::SETTLEMENT_PENDING_GRADE_MESSAGE, flash[:alert]
    assert_equal 1, PendingTransaction.where(target: @contest, tx_type: "settle_contest").count
  end

  test "a settle that failed on chain stays visible for retry: the reason shows on both pages and the row rebuilds" do
    grade
    tx = broadcast_settlement!(@contest.reload, signature: "LifecycleFailedSig#{SecureRandom.hex(8)}")
    chain = Chain.new(statuses: { tx.tx_signature => failed_status(6047) })

    Solana::Vault.stub(:new, chain) { Contests::SettlementSweepJob.perform_now }

    assert_equal "settlement_pending", @contest.reload.status
    assert_equal "pending", tx.reload.status

    get contest_path(@contest)
    assert_select "[data-settlement-notice] [data-settlement-error]", text: /landed and failed on chain/

    Solana::Vault.stub(:new, FakeVault.new) { get admin_pending_transactions_path }
    assert_response :success
    assert_select "[data-settlement-error]", text: /Rebuild the settle transaction and cosign it again\./

    rebuilt = Object.new
    rebuilt.define_singleton_method(:build_settle_contest) { |*_a, **_k| { serialized_tx: "REBUILT_WIRE" } }
    Solana::Vault.stub(:new, rebuilt) do
      post rebuild_admin_pending_transaction_path(slug: tx.slug), as: :json
    end
    assert_response :success
    assert_equal "REBUILT_WIRE", tx.reload.serialized_tx
  end

  test "the cosigned settle, verified on chain, is what settles the contest, clears the reason and tells the winner" do
    grade
    @contest.reload.record_settlement_failure!("the first attempt expired")
    tx = @contest.settlement_transaction

    assert_enqueued_jobs 1, only: WinnerNotificationJob do
      Solana::Vault.stub(:new, FakeVault.new) do
        Solana::Keypair.stub(:encode_base58, ->(k) { k.is_a?(String) ? k : k.to_s }) do
          Solana::TxVerifier.stub(:verify!, true) do
            post broadcast_admin_pending_transaction_path(slug: tx.slug),
                 params: { cosigner_address: Solana::Config::MULTISIG_SIGNERS.first, signed_tx: "SIGNED_WIRE" }, as: :json
          end
        end
      end
    end

    assert_response :success
    @contest.reload
    assert_equal "settled", @contest.status
    assert @contest.onchain_settled?
    assert_nil @contest.settlement_error
    assert_equal "confirmed", tx.reload.status
    assert_equal ["FAKE_SIG_SIGNED_WIRE"], TransactionLog.where(source: @contest, transaction_type: "payout").pluck(:onchain_tx)

    get contest_path(@contest)
    assert_select "[data-settlement-notice]", count: 0
  end

  test "control: a broadcast whose settle does not verify leaves the contest settlement_pending" do
    grade
    tx = @contest.reload.settlement_transaction
    refusing = ->(**) { raise Solana::TxVerifier::VerificationError, "not this contest" }

    Solana::Vault.stub(:new, FakeVault.new) do
      Solana::Keypair.stub(:encode_base58, ->(k) { k.is_a?(String) ? k : k.to_s }) do
        Solana::TxVerifier.stub(:verify!, refusing) do
          post broadcast_admin_pending_transaction_path(slug: tx.slug),
               params: { cosigner_address: Solana::Config::MULTISIG_SIGNERS.first, signed_tx: "SIGNED_WIRE" }, as: :json
        end
      end
    end

    assert_response :unprocessable_entity
    assert_equal "settlement_pending", @contest.reload.status
    refute @contest.onchain_settled?
    assert_equal "submitted", tx.reload.status, "the wire went out, so the row is not re-broadcast"
    assert_equal 0, TransactionLog.where(source: @contest).count
  end

  private

  def grade(as: nil)
    builder = Object.new
    builder.define_singleton_method(:build_settle_contest) do |slug, _winners, **_kw|
      { serialized_tx: Base64.strict_encode64("settle-#{slug}") }
    end
    Solana::Vault.stub(:new, builder) do
      as ? post(grade_contest_path(@contest), as: as) : post(grade_contest_path(@contest))
    end
  end
end
