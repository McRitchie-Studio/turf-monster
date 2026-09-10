require "test_helper"
require "minitest/mock"

# Admin::PendingTransactionsController — the generalized multisig cosign queue.
# Covers the tx_type dispatch added in the unused-instructions cleanup:
# rebuild → the right Vault builder, confirm → the right post-verify DB flip.
# Vault + TxVerifier are stubbed so nothing hits RPC.
class Admin::PendingTransactionsControllerTest < ActionDispatch::IntegrationTest
  USDC = "222Dcu2RgAXE3T8A4mGSG3kQyXaNjqePx7vva1RdWBN9".freeze

  setup do
    @admin   = users(:alex)
    @contest = contests(:one)
    @contest.update!(onchain_contest_id: "onchain_ptx")
  end

  def ptx(tx_type, metadata, target: nil)
    PendingTransaction.create!(
      tx_type: tx_type,
      serialized_tx: "OLD_TX",
      status: "pending",
      target: target,
      initiator_address: "init",
      metadata: metadata.to_json
    )
  end

  # --- rebuild dispatch ---

  test "rebuild dispatches cancel_contest to build_cancel_contest" do
    log_in_as(@admin)
    tx = ptx("cancel_contest", { creator: "Creator11111111111111111111111111111111111" }, target: @contest)
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post rebuild_admin_pending_transaction_path(slug: tx.slug)
    end
    assert_equal 1, vault.cancel_calls.length
    assert_match(/FAKE_TX_cancel/, tx.reload.serialized_tx)
  end

  test "rebuild dispatches register_currency to build_register_currency" do
    log_in_as(@admin)
    tx = ptx("register_currency", { mint: USDC, kind: 0, op_rev_ata: "oprev" })
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post rebuild_admin_pending_transaction_path(slug: tx.slug)
    end
    assert_equal USDC, vault.register_calls.first[:mint]
    assert_match(/FAKE_TX_register/, tx.reload.serialized_tx)
  end

  test "rebuild dispatches deactivate_currency to build_deactivate_currency" do
    log_in_as(@admin)
    tx = ptx("deactivate_currency", { currency_idx: 2 })
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post rebuild_admin_pending_transaction_path(slug: tx.slug)
    end
    assert_equal 2, vault.deactivate_calls.first[:currency_idx]
  end

  test "rebuild dispatches sweep_operator_revenue to build_sweep_operator_revenue" do
    log_in_as(@admin)
    tx = ptx("sweep_operator_revenue", { currency_mint: USDC, treasury_ata: "t", amount: 0 })
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post rebuild_admin_pending_transaction_path(slug: tx.slug)
    end
    assert_equal USDC, vault.sweep_calls.first[:currency_mint]
  end

  # --- confirm post-verify DB state ---

  test "confirm flips onchain_cancelled for cancel_contest" do
    log_in_as(@admin)
    tx = ptx("cancel_contest", { creator: "c" }, target: @contest)
    cosigner = Solana::Config::MULTISIG_SIGNERS.first

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post confirm_admin_pending_transaction_path(slug: tx.slug),
            params: { cosigner_address: cosigner, tx_signature: "sig_cancel" }, as: :json
        end
      end
    end

    assert_equal "confirmed", tx.reload.status
    assert @contest.reload.onchain_cancelled?
    assert_not @contest.onchain_settled?
  end

  test "confirm makes no Contest DB change for register_currency (no target)" do
    log_in_as(@admin)
    tx = ptx("register_currency", { mint: USDC, kind: 0 })
    cosigner = Solana::Config::MULTISIG_SIGNERS.first

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post confirm_admin_pending_transaction_path(slug: tx.slug),
            params: { cosigner_address: cosigner, tx_signature: "sig_reg" }, as: :json
        end
      end
    end

    assert_equal "confirmed", tx.reload.status
  end

  test "confirm still flips onchain_settled for settle_contest" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    cosigner = Solana::Config::MULTISIG_SIGNERS.first

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post confirm_admin_pending_transaction_path(slug: tx.slug),
            params: { cosigner_address: cosigner, tx_signature: "sig_settle" }, as: :json
        end
      end
    end

    assert @contest.reload.onchain_settled?
  end

  test "confirm of settle_contest enqueues winner notifications" do
    log_in_as(@admin)
    @contest.entries.create!(
      user: @admin, status: "complete", rank: 1, payout_cents: 4500, score: 1.0
    )
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    cosigner = Solana::Config::MULTISIG_SIGNERS.first

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          assert_enqueued_jobs 1, only: WinnerNotificationJob do
            post confirm_admin_pending_transaction_path(slug: tx.slug),
              params: { cosigner_address: cosigner, tx_signature: "sig_settle_notify" }, as: :json
          end
        end
      end
    end

    assert @contest.reload.onchain_settled?
  end

  test "confirm of cancel_contest does NOT enqueue winner notifications" do
    log_in_as(@admin)
    @contest.entries.create!(
      user: @admin, status: "complete", rank: 1, payout_cents: 4500, score: 1.0
    )
    tx = ptx("cancel_contest", { creator: "c" }, target: @contest)
    cosigner = Solana::Config::MULTISIG_SIGNERS.first

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          assert_no_enqueued_jobs only: WinnerNotificationJob do
            post confirm_admin_pending_transaction_path(slug: tx.slug),
              params: { cosigner_address: cosigner, tx_signature: "sig_cancel_notify" }, as: :json
          end
        end
      end
    end
  end

  # --- broadcast: server-side send (the cosign fix) ---
  #
  # REGRESSION. The browser used to broadcast the cosigned wire itself, which
  # failed on mainnet every time for three compounding reasons (all measured
  # 2026-09-05): Config.public_rpc_url refuses to hand a credentialed endpoint
  # to a browser, so the page fell back to the throttled public cluster RPC;
  # web3.js Connection defaults to `finalized`, so sendRawTransaction
  # preflighted a fresh blockhash against a bank ~32 slots stale and rejected a
  # VALID tx with BlockhashNotFound; and the page read the tx out of a DOM
  # attribute baked at render time, so clicking Co-sign again re-sent the SAME
  # expired bytes. That silently stranded $140 of alpha-contest payouts in June.
  # Broadcasting server-side removes all three.

  test "broadcast sends the signed wire through the server and flips settle state" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    cosigner = Solana::Config::MULTISIG_SIGNERS.first
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post broadcast_admin_pending_transaction_path(slug: tx.slug),
            params: { cosigner_address: cosigner, signed_tx: "SIGNED_WIRE" }, as: :json
        end
      end
    end

    assert_response :success
    assert_equal ["SIGNED_WIRE"], vault.broadcast_calls
    assert_equal "confirmed", tx.reload.status
    assert @contest.reload.onchain_settled?
  end

  test "broadcast of settle_contest enqueues winner notifications" do
    log_in_as(@admin)
    @contest.entries.create!(user: @admin, status: "complete", rank: 1, payout_cents: 4500, score: 1.0)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    cosigner = Solana::Config::MULTISIG_SIGNERS.first

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          assert_enqueued_jobs 1, only: WinnerNotificationJob do
            post broadcast_admin_pending_transaction_path(slug: tx.slug),
              params: { cosigner_address: cosigner, signed_tx: "SIGNED_WIRE" }, as: :json
          end
        end
      end
    end
  end

  test "broadcast refuses a blank signed wire" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      post broadcast_admin_pending_transaction_path(slug: tx.slug),
        params: { cosigner_address: Solana::Config::MULTISIG_SIGNERS.first, signed_tx: "" }, as: :json
    end

    assert_response :unprocessable_entity
    assert_empty vault.broadcast_calls
    assert_equal "pending", tx.reload.status
  end

  test "broadcast refuses a cosigner outside the multisig set" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      post broadcast_admin_pending_transaction_path(slug: tx.slug),
        params: { cosigner_address: "NotASigner1111111111111111111111111111111", signed_tx: "SIGNED_WIRE" }, as: :json
    end

    assert_response :unprocessable_entity
    assert_empty vault.broadcast_calls
    assert_equal "pending", tx.reload.status
  end

  test "broadcast refuses a transaction that is no longer pending" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    tx.update!(status: "confirmed")
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      post broadcast_admin_pending_transaction_path(slug: tx.slug),
        params: { cosigner_address: Solana::Config::MULTISIG_SIGNERS.first, signed_tx: "SIGNED_WIRE" }, as: :json
    end

    assert_response :unprocessable_entity
    assert_empty vault.broadcast_calls
  end

  # The whole point of moving the broadcast server-side is that the operator
  # learns WHY it failed. The old client blamed an expired blockhash for every
  # failure, including program errors that no amount of retrying would fix.
  test "broadcast surfaces the real failure instead of a blockhash guess" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    vault = FakeVault.new(broadcast_raises: "Pre-flight simulation failed: SettlementOverflow")

    Solana::Vault.stub :new, vault do
      post broadcast_admin_pending_transaction_path(slug: tx.slug),
        params: { cosigner_address: Solana::Config::MULTISIG_SIGNERS.first, signed_tx: "SIGNED_WIRE" }, as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/SettlementOverflow/, JSON.parse(response.body)["error"])
    assert_no_match(/blockhash/i, JSON.parse(response.body)["error"])
    assert_equal "pending", tx.reload.status
  end

  # Rebuild is now what the CLIENT calls at click time to get a tx whose
  # ~60-90s blockhash window starts at the click, not at page render. It must
  # therefore hand the fresh wire back in the JSON body.
  test "rebuild returns the fresh serialized tx in the json body" do
    log_in_as(@admin)
    tx = ptx("cancel_contest", { creator: "Creator11111111111111111111111111111111111" }, target: @contest)

    Solana::Vault.stub :new, FakeVault.new do
      post rebuild_admin_pending_transaction_path(slug: tx.slug), as: :json
    end

    assert_response :success
    assert_match(/FAKE_TX_cancel/, JSON.parse(response.body)["serialized_tx"])
  end

  # --- the index must not ship the wire to the DOM ---
  #
  # REGRESSION for cause #2. `data-tx-serialized` used to carry the whole
  # transaction, rendered with the page. Its blockhash aged from render time,
  # so by the first click it was often already dead — and every subsequent
  # click re-sent the identical expired bytes, which is why ten retries in a
  # row all failed the same way. The button now carries only the slug, and the
  # client asks the server for a fresh transaction when it is clicked.
  test "index does not render the serialized transaction into the page" do
    log_in_as(@admin)
    ptx("settle_contest", { settlements: [] }, target: @contest)

    get admin_pending_transactions_path

    assert_response :success
    assert_no_match(/data-tx-serialized/, response.body)
    assert_no_match(/OLD_TX/, response.body, "the wire itself must never reach the DOM")
  end

  test "index co-sign button passes only the slug and label" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)

    get admin_pending_transactions_path

    assert_match(/data-tx-slug="#{tx.slug}"/, response.body)
    assert_match(/cosignTransaction\(this\.dataset\.txSlug, this\.dataset\.txLabel\)/, response.body)
  end
end
