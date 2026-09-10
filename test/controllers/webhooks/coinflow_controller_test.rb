require "test_helper"

# Coinflow webhook → mint pipeline. The shared-secret Authorization check is the
# entire defense between an attacker and free token minting
# (Webhooks::PaypalControllerTest parity). We exercise the REAL
# Coinflow::Client#verify_webhook_auth against ENV — not a stub — so a broken
# compare fails the suite.
class Webhooks::CoinflowControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  VALIDATION_KEY = "test_coinflow_secret".freeze

  setup do
    @user = users(:jordan)
    @user.update!(
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
  end

  # ── Shared-secret auth ─────────────────────────────────────────────────

  test "rejects a wrong Authorization header → 401, never mints" do
    purchase = create_purchase
    with_webhook_env do
      assert_no_enqueued_jobs do
        post_webhook(settled_event(purchase: purchase), auth: "WRONG")
      end
    end
    assert_response :unauthorized
    assert_equal "pending", purchase.reload.status
  end

  test "fails closed with 401 when the validation key is unconfigured" do
    purchase = create_purchase
    # No with_webhook_env → COINFLOW_WEBHOOK_VALIDATION_KEY blank.
    ensure_key_absent do
      assert_no_enqueued_jobs do
        post_webhook(settled_event(purchase: purchase), auth: "anything")
      end
    end
    assert_response :unauthorized
    assert_equal "pending", purchase.reload.status
  end

  test "rejects malformed JSON → 400 (after auth passes)" do
    with_webhook_env do
      post "/webhooks/coinflow", params: "not-json{",
           headers: { "Content-Type" => "text/plain", "Authorization" => VALIDATION_KEY }
    end
    assert_response :bad_request
  end

  # ── OPSEC-033 parity: refuse sandbox events in production ───────────────

  test "production refuses events when the client is sandbox-configured" do
    purchase = create_purchase
    with_webhook_env do
      Rails.env.stub :production?, true do
        Coinflow::Client.stub :sandbox?, true do
          assert_no_enqueued_jobs do
            post_webhook(settled_event(purchase: purchase))
          end
        end
      end
    end
    assert_response :ok
    assert_equal "pending", purchase.reload.status
  end

  # ── Settled (fulfillment source of truth) ──────────────────────────────

  test "Settled validates then enqueues the mint job and captures the row" do
    purchase = create_purchase
    with_webhook_env do
      assert_enqueued_with(job: TokenPurchaseJob, args: [{
        user_id: @user.id, pack_id: "single", wallet_address: purchase.wallet_address,
        purchase_type: "coinflow", coinflow_reference: purchase.coinflow_reference
      }]) do
        post_webhook(settled_event(purchase: purchase, payment_id: "PAY_WH"))
      end
    end
    assert_response :ok
    purchase.reload
    assert_equal "captured", purchase.status
    assert_equal "PAY_WH", purchase.coinflow_payment_id
  end

  test "Settled resolves the purchase by an explicit reference field too" do
    purchase = create_purchase
    event = {
      "eventType" => "Settled", "id" => "PAY_REF",
      "subtotal" => { "cents" => 1900, "currency" => "USD" },
      "reference" => purchase.coinflow_reference
    }
    with_webhook_env do
      assert_enqueued_with(job: TokenPurchaseJob) { post_webhook(event) }
    end
    assert_equal "captured", purchase.reload.status
  end

  test "Settled with an amount mismatch never mints" do
    purchase = create_purchase
    with_webhook_env do
      assert_no_enqueued_jobs do
        post_webhook(settled_event(purchase: purchase, cents: 49))
      end
    end
    assert_response :ok
    assert_equal "pending", purchase.reload.status
  end

  test "Settled with a malformed (non-hash) subtotal fails closed — acks 200, never 500, never mints" do
    purchase = create_purchase
    # Coinflow documents subtotal as {cents:, currency:}. A bare integer is
    # malformed; before the guard every `.dig("subtotal", …)` raised TypeError →
    # a webhook 500 (and a Coinflow retry-loop). Carry a reference so resolution
    # succeeds and the payload reaches capture_matches? + the rejection-log path.
    malformed = {
      "eventType" => "Settled", "id" => "PAY_MALFORMED",
      "subtotal" => 1900,
      "reference" => purchase.coinflow_reference
    }
    with_webhook_env do
      assert_no_enqueued_jobs do
        post_webhook(malformed)
      end
    end
    assert_response :ok
    assert_equal "pending", purchase.reload.status
  end

  test "Settled for an unmatched customer acks 200 without minting" do
    with_webhook_env do
      assert_no_enqueued_jobs do
        post_webhook({
          "eventType" => "Settled", "id" => "PAY_NOMATCH",
          "subtotal" => { "cents" => 1900, "currency" => "USD" },
          "customerId" => "tm_user_999999"
        })
      end
    end
    assert_response :ok
  end

  test "duplicate Settled redelivery does not double-enqueue (dedup on payment id)" do
    purchase = create_purchase
    # First delivery captures + enqueues.
    with_webhook_env do
      assert_enqueued_with(job: TokenPurchaseJob) do
        post_webhook(settled_event(purchase: purchase, payment_id: "PAY_DUP"))
      end
    end
    purchase.mark_minted!(["sig_0"])

    # Redelivery of the SAME settlement id — carry the reference so resolution
    # still finds the (now minted) row and the dedup branch fires (not a
    # coincidental "no longer pending" miss).
    redelivery = {
      "eventType" => "Settled", "id" => "PAY_DUP",
      "subtotal" => { "cents" => 1900, "currency" => "USD" },
      "reference" => purchase.coinflow_reference
    }
    with_webhook_env do
      assert_no_enqueued_jobs do
        post_webhook(redelivery)
      end
    end
    assert_response :ok
    assert_equal "minted", purchase.reload.status
    assert_equal ["sig_0"], purchase.tx_signatures
  end

  test "Settled for a FROZEN account records the capture but does NOT mint (B4/OPSEC-048)" do
    purchase = create_purchase
    @user.freeze_for_payment_risk!(reason: "prior dispute")
    with_webhook_env do
      assert_no_enqueued_jobs do
        post_webhook(settled_event(purchase: purchase, payment_id: "PAY_FRZ"))
      end
    end
    assert_response :ok
    purchase.reload
    assert_equal "captured", purchase.status, "money moved — forensics keep the capture"
    assert_equal "PAY_FRZ", purchase.coinflow_payment_id
    assert_equal 0, purchase.tx_signatures.length
  end

  test "Settled for a payment-risk-flagged account does NOT mint (OPSEC-036)" do
    purchase = create_purchase
    @user.update!(payment_risk_flag: true)
    with_webhook_env do
      assert_no_enqueued_jobs do
        post_webhook(settled_event(purchase: purchase))
      end
    end
    assert_response :ok
    assert_equal "captured", purchase.reload.status
  end

  # ── Non-mint events ─────────────────────────────────────────────────────

  test "Card Payment Authorized is pre-settlement — logged, never mints" do
    purchase = create_purchase
    with_webhook_env do
      assert_no_enqueued_jobs do
        post_webhook({ "eventType" => "Card Payment Authorized", "id" => "PAY_AUTH",
                       "customerId" => "tm_user_#{@user.id}" })
      end
    end
    assert_response :ok
    assert_equal "pending", purchase.reload.status
  end

  test "unknown event types return 200 and are ignored" do
    with_webhook_env do
      assert_no_enqueued_jobs do
        post_webhook({ "eventType" => "Refunded", "id" => "PAY_X" })
      end
    end
    assert_response :ok
  end

  private

  # ── heterogeneous pending rows (the mixed-pack money regression) ───────────
  #
  # Every other fixture in this file is single/$19, so this whole class was
  # uncovered. Once the buy page offers single AND trio, a buyer can leave an
  # abandoned $19 row and later pay $49. Amount-blind oldest-first resolution
  # bound the settlement to the stale $19 row, capture_matches? failed on the
  # amount, and the buyer was charged $49 for tokens that never minted.
  # Assert the EFFECT — which row captured — not that "a" row was touched.

  test "a trio settlement captures the trio row, not the older abandoned single" do
    with_webhook_env do
      stale = create_purchase(price_cents: 19_00, pack_id: "single", quantity: 1)
      stale.update_column(:created_at, 2.hours.ago)
      trio = create_purchase(price_cents: 49_00, pack_id: "trio", quantity: 3)

      assert_enqueued_with(job: TokenPurchaseJob) do
        post_webhook(settled_event(purchase: trio, cents: 4900))
      end
      assert_response :success

      assert_equal "captured", trio.reload.status, "the $49 row must be the one that settles"
      assert_equal "pending",  stale.reload.status, "the stale $19 row must be left untouched"
    end
  end

  test "a single settlement still captures the single row when a trio is also pending" do
    with_webhook_env do
      single = create_purchase(price_cents: 19_00, pack_id: "single", quantity: 1)
      trio   = create_purchase(price_cents: 49_00, pack_id: "trio", quantity: 3)
      trio.update_column(:created_at, 2.hours.ago)

      post_webhook(settled_event(purchase: single, cents: 1900))
      assert_response :success

      assert_equal "captured", single.reload.status
      assert_equal "pending",  trio.reload.status
    end
  end

  # Money moved and nothing minted is the one failure that must be diagnosable
  # in seconds — it used to be a bare logger.warn nobody tails.
  test "an unmatched settlement records an ErrorLog rather than failing silently" do
    with_webhook_env do
      # A pending row exists, but none at the settled price — so tier 3 resolves
      # to nothing and the settlement matches no purchase at all.
      row = create_purchase(price_cents: 19_00)

      assert_difference "ErrorLog.count", 1 do
        post_webhook(settled_event(purchase: row, cents: 9999))
      end
      assert_response :success
      assert_match(/matched no pending purchase/, ErrorLog.last.message)
    end
  end

  test "an amount-mismatched settlement records an ErrorLog" do
    with_webhook_env do
      row = create_purchase(price_cents: 19_00)
      # Resolves by reference (tier 1), then fails capture_matches? on amount.
      event = settled_event(purchase: row, cents: 1900).merge("reference" => row.coinflow_reference)
      event["subtotal"] = { "cents" => 4900, "currency" => "USD" }

      assert_difference "ErrorLog.count", 1 do
        post_webhook(event)
      end
      assert_response :success
      assert_equal "pending", row.reload.status
      assert_match(/rejected on amount mismatch/, ErrorLog.last.message)
    end
  end

  # ── concurrent settlements (the lost-race money path) ─────────────────────
  #
  # Two settlements, one row: the second loses begin_fulfillment!'s CAS. Before
  # this it logged "already_fulfilled" at INFO, indistinguishable from a benign
  # webhook redelivery — so a buyer paying twice and minting once looked exactly
  # like normal traffic. The recorded payment id is the discriminator.

  # Reaching the claimed row requires TIER-1 resolution (an explicit reference),
  # because tier 3 only sees `pending` rows and cannot re-resolve a captured one.
  # That is the honest shape of this path: a second settlement carrying the same
  # reference is two payments against one order.
  test "a SECOND distinct settlement on a claimed row records an ErrorLog" do
    with_webhook_env do
      row = create_purchase(price_cents: 19_00)
      first = settled_event(purchase: row, payment_id: "PAY_FIRST", cents: 1900)
                .merge("reference" => row.coinflow_reference)
      post_webhook(first)
      assert_equal "captured", row.reload.status
      assert_equal "PAY_FIRST", row.coinflow_payment_id

      # A DIFFERENT settlement now lands on the same claimed row.
      second = settled_event(purchase: row, payment_id: "PAY_SECOND", cents: 1900)
                 .merge("reference" => row.coinflow_reference)
      assert_difference "ErrorLog.count", 1 do
        post_webhook(second)
      end
      assert_response :success
      assert_match(/lost a concurrent race/, ErrorLog.last.message)
      assert_match(/PAY_SECOND/, ErrorLog.last.message)
      assert_equal "PAY_FIRST", row.reload.coinflow_payment_id, "the winner's id must stand"
    end
  end

  # The benign twin — the SAME settlement redelivered. Webhooks arrive more than
  # once by design, and after the first delivery captures the row tier 3 can no
  # longer see it, so this lands in the "unmatched" branch. It must stay quiet:
  # an ErrorLog stream with a false alarm per redelivery is one nobody reads.
  test "a redelivery of the SAME settlement records no ErrorLog" do
    with_webhook_env do
      row = create_purchase(price_cents: 19_00)
      post_webhook(settled_event(purchase: row, payment_id: "PAY_SAME", cents: 1900))
      assert_equal "captured", row.reload.status
      assert_equal "PAY_SAME", row.coinflow_payment_id

      assert_no_difference "ErrorLog.count" do
        post_webhook(settled_event(purchase: row, payment_id: "PAY_SAME", cents: 1900))
      end
      assert_response :success
    end
  end

  # The guard keys on the recorded payment id, so an unknown settlement that
  # matches nothing must STILL raise the alarm — the quiet path above must not
  # have silenced the genuine orphan case.
  test "an unknown settlement still records an ErrorLog after the redelivery guard" do
    with_webhook_env do
      row = create_purchase(price_cents: 19_00)
      post_webhook(settled_event(purchase: row, payment_id: "PAY_KNOWN", cents: 1900))

      assert_difference "ErrorLog.count", 1 do
        post_webhook(settled_event(purchase: row, payment_id: "PAY_STRANGER", cents: 1900))
      end
      assert_match(/matched no pending purchase/, ErrorLog.last.message)
    end
  end

  # A deliberate hold, but still money settled with nothing minted — it resolves
  # only when an operator looks, and a log line summons no one.
  test "a mint withheld for a risk-flagged buyer records an ErrorLog" do
    with_webhook_env do
      row = create_purchase(price_cents: 19_00)
      @user.update!(payment_risk_flag: true)

      assert_difference "ErrorLog.count", 1 do
        post_webhook(settled_event(purchase: row, cents: 1900))
      end
      assert_response :success
      assert_match(/withheld pending review/, ErrorLog.last.message)
      assert_equal "captured", row.reload.status, "the settlement is still recorded"
    end
  end

  def post_webhook(event, auth: VALIDATION_KEY)
    post "/webhooks/coinflow", params: event.to_json, headers: {
      "Content-Type" => "application/json",
      "Authorization" => auth
    }
  end

  def create_purchase(reference: "coinflow_#{SecureRandom.hex(4)}", pack_id: "single", quantity: 1, price_cents: 19_00)
    CoinflowPurchase.create!(
      user: @user,
      coinflow_reference: reference,
      pack_id: pack_id,
      quantity: quantity,
      price_cents: price_cents,
      wallet_address: @user.solana_address,
      status: "pending"
    )
  end

  # A Settled payload: subtotal is the amount WE set (validated); total carries
  # Coinflow's fee on top (never validated). customerId echoes the per-user
  # x-coinflow-auth-user-id so tier-3 resolution finds the pending row.
  def settled_event(purchase:, payment_id: "PAY_#{SecureRandom.hex(4)}", cents: 1900)
    {
      "eventType" => "Settled",
      "id" => payment_id,
      "subtotal" => { "cents" => cents, "currency" => "USD" },
      "fees" => { "cents" => 200, "currency" => "USD" },
      "total" => { "cents" => cents + 200, "currency" => "USD" },
      "merchantId" => "test_merchant",
      "customerId" => "tm_user_#{purchase.user_id}"
    }
  end

  def with_webhook_env
    original = ENV["COINFLOW_WEBHOOK_VALIDATION_KEY"]
    original_merchant = ENV["COINFLOW_MERCHANT_ID"]
    ENV["COINFLOW_WEBHOOK_VALIDATION_KEY"] = VALIDATION_KEY
    ENV.delete("COINFLOW_MERCHANT_ID") # keep the merchant guard inert in tests
    yield
  ensure
    original.nil? ? ENV.delete("COINFLOW_WEBHOOK_VALIDATION_KEY") : ENV["COINFLOW_WEBHOOK_VALIDATION_KEY"] = original
    original_merchant.nil? ? ENV.delete("COINFLOW_MERCHANT_ID") : ENV["COINFLOW_MERCHANT_ID"] = original_merchant
  end

  def ensure_key_absent
    original = ENV["COINFLOW_WEBHOOK_VALIDATION_KEY"]
    ENV.delete("COINFLOW_WEBHOOK_VALIDATION_KEY")
    yield
  ensure
    original.nil? ? ENV.delete("COINFLOW_WEBHOOK_VALIDATION_KEY") : ENV["COINFLOW_WEBHOOK_VALIDATION_KEY"] = original
  end
end
