require "test_helper"
require "minitest/mock"
require "ostruct"

# BL1 + LW8 (Stage 3 audit): the entire defense between an attacker and free
# token minting is the Stripe webhook signature check. Until this file:
# zero tests.
class Webhooks::StripeControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:jordan)
    @user.update!(
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
  end

  # ── Signature verification ─────────────────────────────────────────────

  test "rejects request with bad Stripe signature → 400" do
    bad_sig_raiser = ->(*) { raise Stripe::SignatureVerificationError.new("bad sig", "v1=bogus") }
    Stripe::Webhook.stub :construct_event, bad_sig_raiser do
      post "/webhooks/stripe", params: "{}", headers: stripe_headers
    end
    assert_response :bad_request
  end

  test "JSON::ParserError from construct_event → 400" do
    json_raiser = ->(*) { raise JSON::ParserError, "bad json" }
    Stripe::Webhook.stub :construct_event, json_raiser do
      post "/webhooks/stripe", params: "{}", headers: stripe_headers
    end
    assert_response :bad_request
  end

  # ── OPSEC-033: refuse test events in production ────────────────────────

  test "production refuses test-mode events without further processing" do
    event = checkout_event(sid: "cs_test_1", kind: "tokens", quantity: 1, amount_total: 1900, livemode: false)
    Rails.env.stub :production?, true do
      Stripe::Webhook.stub :construct_event, ->(*_a, **_k) { event } do
        assert_no_enqueued_jobs only: TokenPurchaseJob do
          post "/webhooks/stripe", params: "{}", headers: stripe_headers
        end
      end
    end
    assert_response :ok
  end

  # ── Event routing ──────────────────────────────────────────────────────

  test "checkout.session.completed (kind=tokens) enqueues TokenPurchaseJob" do
    sid = "cs_test_tok_#{SecureRandom.hex(4)}"
    event = checkout_event(sid: sid, kind: "tokens", quantity: 3, amount_total: 4900)
    result = validator_result(sid: sid, kind: "tokens", quantity: 3, amount_total: 4900)

    Stripe::Webhook.stub :construct_event, ->(*_a, **_k) { event } do
      stub_validator(result) do
        assert_enqueued_with(job: TokenPurchaseJob) do
          post "/webhooks/stripe", params: "{}", headers: stripe_headers
        end
      end
    end
    assert_response :ok
  end

  test "checkout.session.completed (kind=deposit) enqueues StripeDepositJob" do
    sid = "cs_test_dep_#{SecureRandom.hex(4)}"
    event = checkout_event(sid: sid, kind: "deposit", amount_total: 2500)
    result = validator_result(sid: sid, kind: "deposit", amount_total: 2500)

    Stripe::Webhook.stub :construct_event, ->(*_a, **_k) { event } do
      stub_validator(result) do
        assert_enqueued_with(job: StripeDepositJob) do
          post "/webhooks/stripe", params: "{}", headers: stripe_headers
        end
      end
    end
    assert_response :ok
  end

  # Money-path integration (fix-stripe-deposit-double-transfer): a DUPLICATE
  # deposit webhook drives StripeDepositJob twice end-to-end, through the real
  # controller and job, but the claim-first ordering funds the user's USDC
  # EXACTLY ONCE. Pre-fix (transfer-first) this moved money twice. Asserts the
  # effect — fund_user invocation count — not a proxy.
  test "duplicate deposit webhook funds the user EXACTLY ONCE (end-to-end)" do
    sid = "cs_test_dep_dup_#{SecureRandom.hex(4)}"
    event = checkout_event(sid: sid, kind: "deposit", amount_total: 2500)
    result = validator_result(sid: sid, kind: "deposit", amount_total: 2500)
    vault = FakeVault.new

    Solana::Keypair.stub :from_encrypted, "fake-kp" do
      Solana::Vault.stub :new, vault do
        Stripe::Webhook.stub :construct_event, ->(*_a, **_k) { event } do
          stub_validator(result) do
            perform_enqueued_jobs do
              post "/webhooks/stripe", params: "{}", headers: stripe_headers # delivery 1
              post "/webhooks/stripe", params: "{}", headers: stripe_headers # delivery 2 (duplicate)
            end
          end
        end
      end
    end
    assert_response :ok

    assert_equal 1, vault.fund_calls.length,
                 "a duplicate deposit webhook must transfer USDC exactly once"
    assert_equal 1, TransactionLog.where(stripe_session_id: sid).count
    assert_equal "completed", TransactionLog.find_by(stripe_session_id: sid).status
  end

  test "checkout.session.completed silently drops when validator rejects" do
    sid = "cs_test_rej_#{SecureRandom.hex(4)}"
    event = checkout_event(sid: sid, kind: "tokens", quantity: 1, amount_total: 1900)
    bad_result = OpenStruct.new(ok?: false, reason: "amount_mismatch", session: nil)

    Stripe::Webhook.stub :construct_event, ->(*_a, **_k) { event } do
      stub_validator(bad_result) do
        assert_no_enqueued_jobs do
          post "/webhooks/stripe", params: "{}", headers: stripe_headers
        end
      end
    end
    assert_response :ok
  end

  # ── B4 dispute/refund hooks ────────────────────────────────────────────

  test "charge.dispute.created flags AND freezes the buyer (B4 / OPSEC-036+048)" do
    sid = "cs_test_disp_#{SecureRandom.hex(4)}"
    StripePurchase.create!(
      user: @user, stripe_session_id: sid,
      quantity: 3, price_cents: 49_00, status: "minted"
    )
    event = OpenStruct.new(
      id: "evt_disp", type: "charge.dispute.created", livemode: true,
      data: OpenStruct.new(object: OpenStruct.new(
        charge: "ch_disp", payment_intent: "pi_disp",
        reason: "fraudulent", amount: 4900
      ))
    )
    fake_sessions = OpenStruct.new(data: [OpenStruct.new(id: sid)])

    Stripe::Checkout::Session.stub :list, ->(*_a, **_k) { fake_sessions } do
      Stripe::Webhook.stub :construct_event, ->(*_a, **_k) { event } do
        post "/webhooks/stripe", params: "{}", headers: stripe_headers
      end
    end

    assert_response :ok
    @user.reload
    assert @user.payment_risk_flag, "OPSEC-036: dispute should flip payment_risk_flag"
    assert @user.frozen?, "B4/OPSEC-048: dispute should freeze the account"
    assert_match(/stripe\.dispute/, @user.frozen_reason)
    assert_match(/charge=ch_disp/, @user.frozen_reason)
  end

  test "charge.refunded marks purchase refunded AND freezes user (B4 / OPSEC-036+048)" do
    sid = "cs_test_ref_#{SecureRandom.hex(4)}"
    purchase = StripePurchase.create!(
      user: @user, stripe_session_id: sid,
      quantity: 3, price_cents: 49_00, status: "minted"
    )
    event = OpenStruct.new(
      id: "evt_ref", type: "charge.refunded", livemode: true,
      data: OpenStruct.new(object: OpenStruct.new(charge: "ch_ref", payment_intent: "pi_ref"))
    )
    fake_sessions = OpenStruct.new(data: [OpenStruct.new(id: sid)])

    Stripe::Checkout::Session.stub :list, ->(*_a, **_k) { fake_sessions } do
      Stripe::Webhook.stub :construct_event, ->(*_a, **_k) { event } do
        post "/webhooks/stripe", params: "{}", headers: stripe_headers
      end
    end

    assert_response :ok
    assert_equal "refunded", purchase.reload.status
    assert @user.reload.frozen?, "B4/OPSEC-048: refund should freeze the account"
    assert_match(/stripe\.refund/, @user.frozen_reason)
  end

  # LW8: end-to-end webhook → freeze → subsequent entry blocked.
  test "end-to-end: dispute webhook freezes user → subsequent contest entry POST is blocked" do
    sid = "cs_test_e2e_#{SecureRandom.hex(4)}"
    StripePurchase.create!(
      user: @user, stripe_session_id: sid,
      quantity: 3, price_cents: 49_00, status: "minted"
    )
    event = OpenStruct.new(
      id: "evt_e2e", type: "charge.dispute.created", livemode: true,
      data: OpenStruct.new(object: OpenStruct.new(
        charge: "ch_e2e", payment_intent: "pi_e2e", reason: "fraudulent", amount: 4900
      ))
    )
    fake_sessions = OpenStruct.new(data: [OpenStruct.new(id: sid)])

    Stripe::Checkout::Session.stub :list, ->(*_a, **_k) { fake_sessions } do
      Stripe::Webhook.stub :construct_event, ->(*_a, **_k) { event } do
        post "/webhooks/stripe", params: "{}", headers: stripe_headers
      end
    end
    assert @user.reload.frozen?, "precondition: dispute should have frozen the user"

    log_in_as @user
    contest = contests(:one)
    post enter_contest_path(contest)
    assert_redirected_to account_path
    assert_match(/on hold/i, flash[:alert])
  end

  # ── Unknown event types ────────────────────────────────────────────────

  test "unknown event types return 200 and are ignored" do
    event = OpenStruct.new(
      id: "evt_unknown", type: "customer.created", livemode: true,
      data: OpenStruct.new(object: OpenStruct.new)
    )
    Stripe::Webhook.stub :construct_event, ->(*_a, **_k) { event } do
      assert_no_enqueued_jobs do
        post "/webhooks/stripe", params: "{}", headers: stripe_headers
      end
    end
    assert_response :ok
  end

  private

  def stripe_headers
    { "Stripe-Signature" => "v1=test", "Content-Type" => "application/json" }
  end

  def checkout_event(sid:, kind:, amount_total:, quantity: nil, livemode: true)
    metadata = {
      "user_id" => @user.id.to_s, "kind" => kind,
      "wallet_address" => @user.solana_address, "amount_cents" => amount_total.to_s
    }
    metadata["quantity"] = quantity.to_s if quantity
    OpenStruct.new(
      id: "evt_#{SecureRandom.hex(4)}",
      type: "checkout.session.completed",
      livemode: livemode,
      data: OpenStruct.new(object: OpenStruct.new(
        id: sid, payment_status: "paid", status: "complete",
        amount_total: amount_total, currency: "usd", livemode: livemode,
        mode: "payment", metadata: metadata, customer_email: @user.email,
        payment_intent: "pi_#{SecureRandom.hex(4)}"
      ))
    )
  end

  def validator_result(sid:, kind:, amount_total:, quantity: nil)
    metadata = { "user_id" => @user.id.to_s, "kind" => kind, "wallet_address" => @user.solana_address }
    metadata["quantity"] = quantity.to_s if quantity
    OpenStruct.new(
      ok?: true, reason: nil,
      session: OpenStruct.new(id: sid, metadata: metadata, amount_total: amount_total)
    )
  end

  def stub_validator(result)
    fake_validator = OpenStruct.new(call: result)
    StripeCheckoutValidator.stub :new, ->(*_a, **_k) { fake_validator } do
      yield
    end
  end
end
