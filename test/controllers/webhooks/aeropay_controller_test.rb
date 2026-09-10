require "test_helper"

# Aeropay webhook → mint pipeline. The HMAC signature check is the entire
# defense between an attacker and free token minting
# (Webhooks::CoinflowControllerTest parity). We exercise the REAL
# Aeropay::Client#verify_webhook against ENV — not a stub — so a broken HMAC
# compare fails the suite.
class Webhooks::AeropayControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  SIGNING_KEY = "test_aeropay_signing_key".freeze

  setup do
    @user = users(:jordan)
    @user.update!(
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
  end

  # ── HMAC signature auth ────────────────────────────────────────────────

  test "rejects a wrong signature → 401, never mints" do
    purchase = create_purchase
    with_webhook_env do
      assert_no_enqueued_jobs do
        post_webhook(completed_event(purchase: purchase), signature: "deadbeef")
      end
    end
    assert_response :unauthorized
    assert_equal "pending", purchase.reload.status
  end

  test "fails closed with 401 when the signing key is unconfigured" do
    purchase = create_purchase
    # No with_webhook_env → AEROPAY_WEBHOOK_SIGNING_KEY blank; sign with the key
    # anyway so only the unconfigured-server branch is under test.
    ensure_key_absent do
      assert_no_enqueued_jobs do
        post_webhook(completed_event(purchase: purchase))
      end
    end
    assert_response :unauthorized
    assert_equal "pending", purchase.reload.status
  end

  test "rejects malformed JSON → 400 (after signature passes)" do
    with_webhook_env do
      body = "not-json{"
      post "/webhooks/aeropay", params: body, headers: {
        "Content-Type" => "text/plain",
        "X-Aeropay-Signature" => sign(body)
      }
    end
    assert_response :bad_request
  end

  # ── OPSEC-033 parity: refuse sandbox events in production ───────────────

  test "production refuses events when the client is sandbox-configured" do
    purchase = create_purchase
    with_webhook_env do
      Rails.env.stub :production?, true do
        Aeropay::Client.stub :sandbox?, true do
          assert_no_enqueued_jobs do
            post_webhook(completed_event(purchase: purchase))
          end
        end
      end
    end
    assert_response :ok
    assert_equal "pending", purchase.reload.status
  end

  # ── transaction_completed (fulfillment source of truth) ────────────────

  test "transaction_completed validates then enqueues the mint job and captures the row" do
    purchase = create_purchase
    with_webhook_env do
      assert_enqueued_with(job: TokenPurchaseJob, args: [{
        user_id: @user.id, pack_id: "single", wallet_address: purchase.wallet_address,
        purchase_type: "aeropay", aeropay_reference: purchase.aeropay_reference
      }]) do
        post_webhook(completed_event(purchase: purchase, transaction_id: "txn_WH"))
      end
    end
    assert_response :ok
    purchase.reload
    assert_equal "captured", purchase.status
    assert_equal "txn_WH", purchase.aeropay_transaction_id
  end

  test "transaction_completed with a scalar amount and no currency acks 200 (never 500) and does not mint" do
    # Regression (Jasper): a scalar `data.amount` with no `currency` used to raise
    # TypeError in AeropayPurchase.currency's unguarded `.dig`, 500ing the webhook
    # BEFORE the CAS — Aeropay retry-loops and a PAID deposit never mints. It must
    # 200-ack with no mint (odd shape → capture_matches? false), not 500.
    purchase = create_purchase
    event = {
      "topic" => "transaction_completed",
      "data" => {
        "id" => "txn_scalar_no_ccy",
        "amount" => "19.00", # scalar, NO currency key
        "externalId" => purchase.aeropay_reference,
        "customerId" => "tm_user_#{purchase.user_id}"
      }
    }
    with_webhook_env do
      assert_no_enqueued_jobs { post_webhook(event) }
    end
    assert_response :ok
    assert_equal "pending", purchase.reload.status
  end

  test "transaction_completed resolves by the stamped transaction id (tier 1)" do
    purchase = create_purchase(transaction_id: "txn_STAMPED")
    event = {
      "topic" => "transaction_completed",
      "data" => { "id" => "txn_STAMPED", "amount" => "19.00", "currency" => "USD" }
    }
    with_webhook_env do
      assert_enqueued_with(job: TokenPurchaseJob) { post_webhook(event) }
    end
    assert_equal "captured", purchase.reload.status
  end

  test "transaction_completed resolves by our externalId (tier 2)" do
    purchase = create_purchase
    event = {
      "topic" => "transaction_completed",
      "data" => { "id" => "txn_UNSEEN", "amount" => "19.00", "currency" => "USD",
                  "externalId" => purchase.aeropay_reference }
    }
    with_webhook_env do
      assert_enqueued_with(job: TokenPurchaseJob) { post_webhook(event) }
    end
    assert_equal "captured", purchase.reload.status
  end

  test "transaction_completed with an amount mismatch never mints" do
    purchase = create_purchase
    with_webhook_env do
      assert_no_enqueued_jobs do
        post_webhook(completed_event(purchase: purchase, amount: "0.49"))
      end
    end
    assert_response :ok
    assert_equal "pending", purchase.reload.status
  end

  test "transaction_completed for an unmatched customer acks 200 without minting" do
    with_webhook_env do
      assert_no_enqueued_jobs do
        post_webhook({
          "topic" => "transaction_completed",
          "data" => { "id" => "txn_NOMATCH", "amount" => "19.00", "currency" => "USD",
                      "customerId" => "tm_user_999999" }
        })
      end
    end
    assert_response :ok
  end

  test "duplicate transaction_completed redelivery does not double-enqueue (dedup on transaction id)" do
    purchase = create_purchase(transaction_id: "txn_DUP")
    # First delivery captures + enqueues.
    with_webhook_env do
      assert_enqueued_with(job: TokenPurchaseJob) do
        post_webhook(completed_event(purchase: purchase, transaction_id: "txn_DUP"))
      end
    end
    purchase.mark_minted!(["sig_0"])

    # Redelivery of the SAME transaction id — resolves the (now minted) row and
    # the dedup branch fires.
    with_webhook_env do
      assert_no_enqueued_jobs do
        post_webhook(completed_event(purchase: purchase, transaction_id: "txn_DUP"))
      end
    end
    assert_response :ok
    assert_equal "minted", purchase.reload.status
    assert_equal ["sig_0"], purchase.tx_signatures
  end

  test "transaction_completed for a FROZEN account records the capture but does NOT mint (B4/OPSEC-048)" do
    purchase = create_purchase
    @user.freeze_for_payment_risk!(reason: "prior dispute")
    with_webhook_env do
      assert_no_enqueued_jobs do
        post_webhook(completed_event(purchase: purchase, transaction_id: "txn_FRZ"))
      end
    end
    assert_response :ok
    purchase.reload
    assert_equal "captured", purchase.status, "money moved — forensics keep the capture"
    assert_equal "txn_FRZ", purchase.aeropay_transaction_id
    assert_equal 0, purchase.tx_signatures.length
  end

  test "transaction_completed for a payment-risk-flagged account does NOT mint (OPSEC-036)" do
    purchase = create_purchase
    @user.update!(payment_risk_flag: true)
    with_webhook_env do
      assert_no_enqueued_jobs do
        post_webhook(completed_event(purchase: purchase))
      end
    end
    assert_response :ok
    assert_equal "captured", purchase.reload.status
  end

  # ── Non-mint topics ─────────────────────────────────────────────────────

  test "transaction_declined / refunded / voided are logged, never mint, ack 200" do
    %w[transaction_declined transaction_refunded transaction_voided].each do |topic|
      purchase = create_purchase
      with_webhook_env do
        assert_no_enqueued_jobs do
          post_webhook({ "topic" => topic, "data" => { "id" => "txn_#{topic}",
                         "externalId" => purchase.aeropay_reference } })
        end
      end
      assert_response :ok
      assert_equal "pending", purchase.reload.status, "#{topic} must not mutate the row (parity with Coinflow)"
    end
  end

  test "unknown topics return 200 and are ignored" do
    with_webhook_env do
      assert_no_enqueued_jobs do
        post_webhook({ "topic" => "customer_updated", "data" => { "id" => "txn_X" } })
      end
    end
    assert_response :ok
  end

  private

  def sign(raw_body)
    OpenSSL::HMAC.hexdigest("SHA256", SIGNING_KEY, raw_body)
  end

  def post_webhook(event, signature: nil)
    body = event.to_json
    post "/webhooks/aeropay", params: body, headers: {
      "Content-Type" => "application/json",
      "X-Aeropay-Signature" => signature || sign(body)
    }
  end

  def create_purchase(reference: "aeropay_#{SecureRandom.hex(4)}", transaction_id: nil,
                      pack_id: "single", quantity: 1, price_cents: 19_00)
    AeropayPurchase.create!(
      user: @user,
      aeropay_reference: reference,
      aeropay_transaction_id: transaction_id,
      pack_id: pack_id,
      quantity: quantity,
      price_cents: price_cents,
      wallet_address: @user.solana_address,
      status: "pending"
    )
  end

  # A transaction_completed payload: `data.amount` is the deposit amount we
  # validate, in decimal dollars, and `externalId` echoes our reference so
  # resolution finds the row. [FLAG] amount/field shapes are doc-derived.
  def completed_event(purchase:, transaction_id: "txn_#{SecureRandom.hex(4)}", amount: "19.00")
    {
      "topic" => "transaction_completed",
      "payloadVersion" => "1",
      "date" => Time.current.iso8601,
      "data" => {
        "id" => transaction_id,
        "amount" => amount,
        "currency" => "USD",
        "externalId" => purchase.aeropay_reference,
        "merchantId" => "test_merchant",
        "customerId" => "tm_user_#{purchase.user_id}"
      }
    }
  end

  def with_webhook_env
    original = ENV["AEROPAY_WEBHOOK_SIGNING_KEY"]
    original_merchant = ENV["AEROPAY_MERCHANT_ID"]
    ENV["AEROPAY_WEBHOOK_SIGNING_KEY"] = SIGNING_KEY
    ENV.delete("AEROPAY_MERCHANT_ID") # keep the merchant guard inert in tests
    yield
  ensure
    original.nil? ? ENV.delete("AEROPAY_WEBHOOK_SIGNING_KEY") : ENV["AEROPAY_WEBHOOK_SIGNING_KEY"] = original
    original_merchant.nil? ? ENV.delete("AEROPAY_MERCHANT_ID") : ENV["AEROPAY_MERCHANT_ID"] = original_merchant
  end

  def ensure_key_absent
    original = ENV["AEROPAY_WEBHOOK_SIGNING_KEY"]
    ENV.delete("AEROPAY_WEBHOOK_SIGNING_KEY")
    yield
  ensure
    original.nil? ? ENV.delete("AEROPAY_WEBHOOK_SIGNING_KEY") : ENV["AEROPAY_WEBHOOK_SIGNING_KEY"] = original
  end
end
