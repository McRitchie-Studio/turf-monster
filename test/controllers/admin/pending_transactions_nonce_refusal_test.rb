require "test_helper"
require "minitest/mock"

# [integration] A NONCE-ANCHORED SETTLE NEVER GOES TO PHANTOM.
#
# Phantom puts Lighthouse ahead of advanceNonceAccount, so the Treasury page's
# Co-sign and Rebuild refuse a nonce row before any vault call, and name
# bin/settle-nonce. A blockhash row is the control.
class Admin::PendingTransactionsNonceRefusalTest < ActionDispatch::IntegrationTest
  setup do
    @contest = contests(:one)
    @contest.update_columns(onchain_contest_id: "onchain_nonce_refusal", status: "settlement_pending")
    log_in_as(users(:alex))
  end

  def row(metadata)
    PendingTransaction.create!(tx_type: "settle_contest", serialized_tx: "WIRE", status: "pending",
                               target: @contest, initiator_address: "init", metadata: metadata.to_json)
  end

  def nonce_row
    row(settlements: [], durable_nonce: { account: "Nonce", authority: "Cli", value: "Value" })
  end

  def exploding_vault
    -> { raise "the vault must not be reached" }
  end

  test "broadcast refuses a nonce row and sends nothing" do
    tx = nonce_row
    Solana::Vault.stub(:new, exploding_vault) do
      post broadcast_admin_pending_transaction_path(slug: tx.slug),
           params: { cosigner_address: Solana::Config::MULTISIG_SIGNERS.first, signed_tx: "SIGNED" }, as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/nonce-anchored: cosign it with bin\/settle-nonce/, response.parsed_body["error"])
    assert_equal ["pending", nil], [tx.reload.status, tx.tx_signature]
  end

  test "rebuild refuses a nonce row and keeps its bytes" do
    tx = nonce_row
    Solana::Vault.stub(:new, exploding_vault) do
      post rebuild_admin_pending_transaction_path(slug: tx.slug), as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/bin\/settle-nonce/, response.parsed_body["error"])
    assert_equal "WIRE", tx.reload.serialized_tx
  end

  test "control: a blockhash row reaches the vault on rebuild" do
    tx = row(settlements: [])
    reached = false
    vault = Object.new
    vault.define_singleton_method(:build_settle_contest) { |*_a, **_k| reached = true; { serialized_tx: "REBUILT" } }

    Solana::Vault.stub(:new, vault) do
      post rebuild_admin_pending_transaction_path(slug: tx.slug), as: :json
    end

    assert reached
    assert_equal "REBUILT", tx.reload.serialized_tx
  end
end
