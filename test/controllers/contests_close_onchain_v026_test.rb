require "test_helper"
require "minitest/mock"

# The admin "Reclaim rent" button on turf-vault v0.26, where CLOSE_CONTEST
# needs two vault signatures and the server holds one.
#
# The server signs its half and queues the transaction for a Phantom cosign in
# the Treasury, as cancel_onchain does. The queued wire is decoded here: two
# signer slots, the server's filled, the cosigner's empty and sitting in the
# first remaining account where `authorize` reads it. v0.25 keeps the
# one-signature server close (contests_onchain_lifecycle_test.rb).
class ContestsCloseOnchainV026Test < ActionDispatch::IntegrationTest
  COSIGNER = Solana::Config::MULTISIG_COSIGNER
  EMPTY = ("\x00" * 64).b

  setup do
    @admin = users(:alex)
    @contest = contests(:one)
    @contest.update!(status: :settled, onchain_contest_id: "onchain_close_v026")
  end

  # Only the RPC is stood in for: a fixed blockhash, and no account anywhere,
  # so the GovernanceConfig read falls back to the defaults (close = 2).
  def fake_client
    Object.new.tap do |c|
      c.define_singleton_method(:get_latest_blockhash) { |**| Solana::Keypair.encode_base58((1..32).to_a.pack("C*")) }
      c.define_singleton_method(:get_account_info) { |*_args, **_kw| { "value" => nil } }
      c.define_singleton_method(:send_and_confirm) { |_wire| raise "v0.26 close must not broadcast from the server" }
    end
  end

  def press_close(governance:)
    vault = Solana::Vault.new(client: fake_client)
    log_in_as(@admin)
    Solana::Config.stub(:governance?, governance) do
      Solana::Vault.stub(:cached_vault_state, nil) do
        Solana::Vault.stub(:new, vault) { post close_onchain_contest_path(@contest) }
      end
    end
  end

  def key(bytes) = Solana::Keypair.encode_base58(bytes)

  test "v0.26 queues a two-signer close for a Treasury cosign" do
    assert_difference -> { PendingTransaction.where(tx_type: "close_contest").count }, 1 do
      press_close(governance: true)
    end
    assert_redirected_to admin_pending_transactions_path
    refute @contest.reload.onchain_closed?, "nothing is closed until the cosign lands"

    ptx = PendingTransaction.find_by!(tx_type: "close_contest", target: @contest)
    assert_equal "pending", ptx.status
    assert_equal 2, ptx.required_signatures

    wire = Solana::WireMessage.parse_base64(ptx.serialized_tx)
    assert_equal 2, wire.num_required_signatures
    signers = wire.account_keys.first(2).map { |k| key(k) }
    assert_equal [Solana::Keypair.admin.to_base58, COSIGNER], signers
    refute_equal EMPTY, wire.signatures[0], "the server signed its half"
    assert_equal EMPTY, wire.signatures[1], "the cosigner's slot is left for Phantom"

    close = wire.instructions.find { |ix| ix[:data].b.start_with?(Solana::Transaction.anchor_discriminator("close_contest")) }
    accounts = close[:account_indices].map { |i| key(wire.account_keys[i]) }
    vault = Solana::Vault.new(client: fake_client)
    assert_equal key(vault.governance_pda.first), accounts[2], "governance follows vault_state"
    assert_equal COSIGNER, accounts.last, "the cosigner is the first remaining account"
    assert_equal 10, accounts.size, "nine named accounts plus one cosigner"
  end

  test "a second press does not stack a second cosign" do
    press_close(governance: true)
    assert_no_difference -> { PendingTransaction.where(tx_type: "close_contest").count } do
      press_close(governance: true)
    end
  end

  test "v0.25 still closes server-signed with no queued row" do
    vault = FakeVault.new
    log_in_as(@admin)
    Solana::Config.stub(:governance?, false) do
      Solana::Vault.stub(:new, vault) { post close_onchain_contest_path(@contest) }
    end

    assert_equal [@contest.slug], vault.close_calls
    assert @contest.reload.onchain_closed?
    assert_empty PendingTransaction.where(tx_type: "close_contest")
  end

  def queued_close
    PendingTransaction.create!(tx_type: "close_contest", serialized_tx: "OLD_TX", status: "pending",
                               target: @contest, initiator_address: "init", metadata: {}.to_json)
  end

  test "the Treasury rebuild builds a fresh cosigned close" do
    tx = queued_close
    vault = FakeVault.new
    log_in_as(@admin)
    Solana::Config.stub(:governance?, true) do
      Solana::Vault.stub(:new, vault) { post rebuild_admin_pending_transaction_path(slug: tx.slug), as: :json }
    end

    assert_response :success
    assert_equal [{ slug: @contest.slug, cosigner: COSIGNER, extra_cosigners: [] }], vault.close_build_calls
    assert_equal "FAKE_TX_close_#{@contest.slug}", tx.reload.serialized_tx
  end

  test "a verified close cosign flips onchain_closed" do
    tx = queued_close
    log_in_as(@admin)
    Solana::Config.stub(:governance?, true) do
      Solana::Vault.stub(:new, FakeVault.new) do
        Solana::TxVerifier.stub(:verify!, true) do
          post confirm_admin_pending_transaction_path(slug: tx.slug),
               params: { cosigner_address: COSIGNER, tx_signature: "sig_close" }, as: :json
        end
      end
    end

    assert_equal "confirmed", tx.reload.status
    assert @contest.reload.onchain_closed?
  end

  test "the Treasury rebuild and the cosign plan know close_contest" do
    plan = Solana::CosignPlan.new(tx_type: "close_contest")
    Solana::Config.stub(:governance?, true) do
      assert_equal 2, plan.required_signatures
      assert_equal 0, plan.extra_cosigners_needed, "the one Phantom signature is the primary cosigner"
    end
  end
end
