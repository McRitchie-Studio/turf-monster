class TokensController < ApplicationController
  before_action :require_login
  before_action :require_dev_mint_allowed, only: [:dev_mint]
  # B4 / OPSEC-048: frozen accounts can't buy tokens.
  before_action :require_unfrozen_account, only: [:stripe_checkout, :paypal_order, :paypal_capture, :coinflow_order, :aeropay_order]

  def buy
    @packs = StripePurchase.available_packs
    if Payments.paypal_checkout?
      # The PayPal flow finishes on this page (no /tokens/processing redirect),
      # so its success card needs the same "Enter contest" target processing
      # resolves. Stripe path skips the queries — rendering there is unchanged.
      @next_contest = Contest.target ||
                      Contest.where(status: :open).order(created_at: :desc).first
    end
  end

  def stripe_checkout
    pack_id = params[:pack].to_s
    unless StripePurchase.available_packs.key?(pack_id)
      return redirect_to tokens_buy_path, alert: "Unknown or unavailable token pack"
    end
    unless current_user.solana_connected?
      return redirect_to tokens_buy_path, alert: "Connect a wallet first."
    end
    # Distinct messages, one truth: missing/kill-switched Stripe config reads
    # as unconfigured; a different active provider reads as disabled. Both
    # keep stale tabs / scripted clients off the blocked Stripe account.
    unless Rails.application.config.x.stripe_enabled
      return redirect_to tokens_buy_path, alert: "Card checkout isn't configured yet. Set STRIPE_SECRET_KEY and restart."
    end
    unless Payments.stripe?
      return redirect_to tokens_buy_path, alert: "Card checkout is currently disabled."
    end
    # OPSEC-036: a prior chargeback flagged this account — block further card
    # purchases so a stolen-card buyer can't keep racking up disputes.
    if current_user.payment_risk_flag
      return redirect_to tokens_buy_path, alert: "Card purchases are disabled on this account. Please contact support."
    end

    pack        = StripePurchase.pack(pack_id)
    quantity    = pack[:quantity]
    price_cents = pack[:price_cents]
    # Optional contest context — when present, checkout returns the buyer to
    # that contest (lineup preserved) instead of the generic token page.
    contest = Contest.find_by(slug: params[:contest].presence)

    rescue_and_log(target: current_user) do
      session_params = {
        payment_method_types: ["card"],
        line_items: [{
          price_data: {
            currency: "usd",
            product_data: { name: "Turf Monster — #{quantity} entry token#{'s' if quantity != 1}" },
            unit_amount: price_cents
          },
          quantity: 1
        }],
        mode: "payment",
        success_url: contest ?
          "#{tokens_processing_url}?session_id={CHECKOUT_SESSION_ID}&contest=#{contest.slug}" :
          "#{tokens_processing_url}?session_id={CHECKOUT_SESSION_ID}",
        cancel_url:  contest ? contest_url(contest) : "#{tokens_buy_url}?purchase=cancelled",
        metadata: {
          kind: "tokens",
          user_id: current_user.id,
          pack_id: pack_id,
          quantity: quantity,
          wallet_address: current_user.solana_address,
          contest_slug: contest&.slug
        }
      }
      # Pre-fill the email field if we have one. Stripe rejects the request if
      # both `customer` and `customer_email` are passed, so we only set this
      # when there's no Stripe customer attached yet.
      session_params[:customer_email] = current_user.email if current_user.email.present?

      session = Stripe::Checkout::Session.create(session_params)

      respond_to do |format|
        # Same-tab HTML submit (e.g. /tokens/buy) → server-side redirect.
        format.html { redirect_to session.url, allow_other_host: true }
        # XHR / fetch from the in-modal pack button → return the URL
        # as JSON so the client navigates the already-open tab itself.
        # If we redirected here, fetch would follow the 302 to Stripe
        # and consume the checkout session before the user got to it
        # (Stripe shows "page not found" on second visit).
        format.json { render json: { url: session.url } }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to tokens_buy_path, alert: "Checkout failed: #{e.message}" }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  # PayPal JS SDK createOrder callback (Venmo + PayPal standalone buttons).
  # JSON-only — the buttons keep the buyer on-page and drive the approval
  # popup/app-switch themselves, so there is no redirect leg like Stripe's.
  # Mirrors stripe_checkout's gates; the amount derives SERVER-SIDE from the
  # pack definition — the client only ever names a pack id.
  def paypal_order
    pack_id = params[:pack].to_s
    unless StripePurchase.available_packs.key?(pack_id)
      return render json: { error: "Unknown or unavailable token pack" }, status: :unprocessable_entity
    end
    unless current_user.solana_connected?
      return render json: { error: "Connect a wallet first." }, status: :unprocessable_entity
    end
    unless paypal_checkout_enabled?
      return render json: { error: "PayPal checkout isn't enabled." }, status: :unprocessable_entity
    end
    # OPSEC-036: a prior chargeback flagged this account — block further fiat
    # purchases so a stolen-card buyer can't keep racking up disputes.
    if current_user.payment_risk_flag
      return render json: { error: "Purchases are disabled on this account. Please contact support." }, status: :forbidden
    end

    pack    = StripePurchase.pack(pack_id)
    contest = Contest.find_by(slug: params[:contest].presence)

    rescue_and_log(target: current_user) do
      # Row first, order second: Current.outbound_source needs the purchase to
      # exist so the create-order API call lands in outbound_requests with
      # polymorphic attribution (same ordering as TokenPurchaseJob).
      @paypal_purchase = PaypalPurchase.create!(
        user: current_user,
        pack_id: pack_id,
        quantity: pack[:quantity],
        price_cents: pack[:price_cents],
        wallet_address: current_user.solana_address,
        contest_slug: contest&.slug,
        status: "pending"
      )
      Current.outbound_source = @paypal_purchase

      order = Paypal::Client.new.create_order(pack: pack, user: current_user, purchase: @paypal_purchase)
      @paypal_purchase.update!(paypal_order_id: order["id"])
      Rails.logger.info "[tokens] paypal.order_created purchase=#{@paypal_purchase.id} order=#{order['id']} pack=#{pack_id} user=#{current_user.id}"
      render json: { order_id: order["id"] }
    end
  rescue StandardError => e
    @paypal_purchase&.mark_failed_unless_minted!
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # PayPal JS SDK onApprove callback — capture the approved order server-side,
  # validate PayPal's authoritative response (COMPLETED / USD / exact pack
  # amount), then hand off to the exactly-once mint gate. The webhook's
  # PAYMENT.CAPTURE.COMPLETED + CHECKOUT.ORDER.APPROVED handlers cover the
  # client-died path; Paypal::Fulfillment arbitrates the race.
  def paypal_capture
    order_id = params[:order_id].to_s
    return render json: { error: "order_id required" }, status: :bad_request if order_id.blank?

    purchase = current_user.paypal_purchases.for_order(order_id).first
    return render json: { error: "Purchase not found" }, status: :not_found unless purchase

    # Idempotent retry: fulfillment already started (webhook fallback won, or
    # a duplicate click) — report current status, never re-capture.
    return render json: { status: purchase.status } unless purchase.status == "pending"

    # OPSEC-036: the flag can flip between order creation and capture (e.g. an
    # operator console flag without a freeze) — re-check before the money
    # moves, exactly as paypal_order/stripe_checkout gate at their entry.
    if current_user.payment_risk_flag
      return render json: { error: "Purchases are disabled on this account. Please contact support." }, status: :forbidden
    end

    rescue_and_log(target: current_user) do
      Current.outbound_source = purchase
      response = Paypal::Client.new.capture_order(order_id)
      capture  = response.dig("purchase_units", 0, "payments", "captures", 0)
      TokensLogger.dump("paypal.capture_response", {
        order_id: order_id,
        order_status: response["status"],
        capture_id: capture&.dig("id"),
        capture_status: capture&.dig("status"),
        amount: capture&.dig("amount")
      })

      unless response["status"] == "COMPLETED" && purchase.capture_matches?(capture)
        # eCheck / Venmo-review holds come back capture status PENDING with the
        # buyer's money already initiated — NOT a failure. Treating it as one
        # invited a "try again" retry that created a second order = a real
        # double charge. Report a processing hold instead; the row stays
        # pending so PAYMENT.CAPTURE.COMPLETED wins the CAS and mints when the
        # hold clears (days for eCheck).
        if purchase.capture_pending?(capture)
          Rails.logger.warn "[tokens] paypal.capture_pending_hold purchase=#{purchase.id} order=#{order_id} " \
                            "capture=#{capture['id']} — payment initiated, awaiting PAYMENT.CAPTURE.COMPLETED"
          return render json: { status: "processing" }
        end
        Rails.logger.warn "[tokens] paypal.capture_invalid purchase=#{purchase.id} order=#{order_id} " \
                          "order_status=#{response['status']} capture_status=#{capture&.dig('status')} " \
                          "amount=#{capture&.dig('amount', 'value')} expected=#{purchase.expected_amount_value}"
        return render json: { error: "Payment could not be confirmed." }, status: :unprocessable_entity
      end

      Paypal::Fulfillment.enqueue_mint!(purchase, capture_id: capture["id"])
      render json: { status: purchase.reload.status }
    end
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Coinflow hosted-checkout kickoff (additive rail, gated on AppFlags.coinflow?).
  # JSON-only. Coinflow's flow is a redirect (no client-side capture leg): we
  # create the pending purchase row FIRST, ask Coinflow for a hosted-checkout
  # link, and hand the browser that link. On `Settled` the webhook mints exactly
  # 1 entry token (Webhooks::CoinflowController) — the same on-chain end state as
  # the PayPal token-buy. The amount derives SERVER-SIDE from the pack; the
  # client only ever names a pack id.
  def coinflow_order
    pack_id = params[:pack].to_s
    unless StripePurchase.available_packs.key?(pack_id)
      return render json: { error: "Unknown or unavailable token pack" }, status: :unprocessable_entity
    end
    unless current_user.solana_connected?
      return render json: { error: "Connect a wallet first." }, status: :unprocessable_entity
    end
    unless AppFlags.coinflow?
      return render json: { error: "Coinflow checkout isn't enabled." }, status: :unprocessable_entity
    end
    # OPSEC-036: a prior chargeback flagged this account — block further fiat
    # purchases so a stolen-card buyer can't keep racking up disputes.
    if current_user.payment_risk_flag
      return render json: { error: "Purchases are disabled on this account. Please contact support." }, status: :forbidden
    end

    pack    = StripePurchase.pack(pack_id)
    contest = Contest.find_by(slug: params[:contest].presence)

    rescue_and_log(target: current_user) do
      # Row first, link second: Current.outbound_source needs the purchase to
      # exist so the create-link API call lands in outbound_requests with
      # polymorphic attribution (same ordering as paypal_order / TokenPurchaseJob).
      @coinflow_purchase = CoinflowPurchase.create!(
        user: current_user,
        pack_id: pack_id,
        quantity: pack[:quantity],
        price_cents: pack[:price_cents],
        wallet_address: current_user.solana_address,
        contest_slug: contest&.slug,
        status: "pending"
      )
      # The reference IS the slug — set once here (the slug exists only after
      # Sluggable's before_save fires on create), then immutable and echoed by
      # Coinflow / carried on the callback for settlement resolution.
      @coinflow_purchase.update!(coinflow_reference: @coinflow_purchase.slug)
      Current.outbound_source = @coinflow_purchase

      return_url = "#{tokens_buy_url}?coinflow=return&reference=#{@coinflow_purchase.coinflow_reference}"
      link = Coinflow::Client.new.create_checkout_link(
        user: current_user, pack: pack, pack_id: pack_id,
        return_url: return_url, ip: request.remote_ip
      )
      Rails.logger.info "[tokens] coinflow.order_created purchase=#{@coinflow_purchase.id} " \
                        "reference=#{@coinflow_purchase.coinflow_reference} pack=#{pack_id} user=#{current_user.id}"
      render json: { link: link, reference: @coinflow_purchase.coinflow_reference }
    end
  rescue StandardError => e
    @coinflow_purchase&.mark_failed_unless_minted!
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Aeropay bank-payment kickoff (additive rail, gated on AppFlags.aeropay?).
  # JSON-only. Aeropay is BANK rails (pay-by-bank ACH + RTP), not a hosted
  # redirect: the buyer links a bank via the front-end Aerosync widget (STUBBED
  # until merchant creds land — see tokens/_aeropay_script), the client posts the
  # resulting bankAccountId here, we create the pending purchase row FIRST, then
  # ask Aeropay to create the deposit (POST /v2/transaction). On
  # `transaction_completed` the webhook mints exactly 1 entry token
  # (Webhooks::AeropayController) — the same on-chain end state as the Coinflow /
  # PayPal token-buy. The amount derives SERVER-SIDE from the pack; the client
  # only ever names a pack id + the linked bank account.
  #
  # SETTLEMENT CAVEAT: a `transaction_completed` for a standard ACH pay-in is
  # APPROVED, not settled (~3 business days). Production should prefer the instant
  # RfP/RTP pay-in (irrevocable) so funds are final before the mint — see
  # Aeropay::Client#create_deposit.
  def aeropay_order
    pack_id = params[:pack].to_s
    unless StripePurchase.available_packs.key?(pack_id)
      return render json: { error: "Unknown or unavailable token pack" }, status: :unprocessable_entity
    end
    unless current_user.solana_connected?
      return render json: { error: "Connect a wallet first." }, status: :unprocessable_entity
    end
    unless AppFlags.aeropay?
      return render json: { error: "Aeropay checkout isn't enabled." }, status: :unprocessable_entity
    end
    # OPSEC-036: a prior chargeback flagged this account — block further fiat
    # purchases so a stolen-account buyer can't keep racking up disputes.
    if current_user.payment_risk_flag
      return render json: { error: "Purchases are disabled on this account. Please contact support." }, status: :forbidden
    end
    # The linked bank account from the front-end Aerosync widget. STUBBED until
    # merchant creds land (the widget can't load without them) — the server
    # trusts nothing but this id; the amount still derives from the pack. Refuse
    # a blank id BEFORE writing a row so we never orphan a pending purchase.
    bank_account_id = params[:bank_account_id].to_s
    if bank_account_id.blank?
      return render json: { error: "Link a bank account first." }, status: :unprocessable_entity
    end

    pack    = StripePurchase.pack(pack_id)
    contest = Contest.find_by(slug: params[:contest].presence)

    rescue_and_log(target: current_user) do
      # Row first, deposit second: Current.outbound_source needs the purchase to
      # exist so the create-deposit API call lands in outbound_requests with
      # polymorphic attribution (same ordering as coinflow_order / paypal_order).
      @aeropay_purchase = AeropayPurchase.create!(
        user: current_user,
        pack_id: pack_id,
        quantity: pack[:quantity],
        price_cents: pack[:price_cents],
        wallet_address: current_user.solana_address,
        contest_slug: contest&.slug,
        status: "pending"
      )
      # The reference IS the slug — set once here (the slug exists only after
      # Sluggable's before_save fires on create), then immutable and sent to
      # Aeropay as externalId / echoed on the webhook for settlement resolution.
      @aeropay_purchase.update!(aeropay_reference: @aeropay_purchase.slug)
      Current.outbound_source = @aeropay_purchase

      deposit = Aeropay::Client.new.create_deposit(
        user: current_user, pack: pack, bank_account_id: bank_account_id,
        reference: @aeropay_purchase.aeropay_reference,
        idempotency_key: @aeropay_purchase.aeropay_reference
      )
      # persist-before-mint: stamp the deposit's transaction id (the dedup key +
      # what `transaction_completed` echoes back) BEFORE anything mints.
      @aeropay_purchase.update!(aeropay_transaction_id: deposit["id"])
      Rails.logger.info "[tokens] aeropay.order_created purchase=#{@aeropay_purchase.id} " \
                        "reference=#{@aeropay_purchase.aeropay_reference} transaction=#{deposit['id']} " \
                        "pack=#{pack_id} user=#{current_user.id}"
      render json: {
        transaction_id: deposit["id"],
        reference: @aeropay_purchase.aeropay_reference,
        status: deposit["status"]
      }
    end
  rescue StandardError => e
    @aeropay_purchase&.mark_failed_unless_minted!
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Dev/QA only (not drawn in production): stand in for Coinflow's `Settled`
  # webhook, which can't reach a localhost stack. Drives the SAME money-path
  # components the real webhook uses — CoinflowPurchase#capture_matches? +
  # Coinflow::Fulfillment.enqueue_mint! (the exactly-once CAS + mint) — just
  # without the shared-secret HTTP hop. Mirrors the dev-mint affordance.
  def coinflow_simulate_settle
    return head :not_found if Rails.env.production?

    purchase = current_user.coinflow_purchases.where(status: "pending").order(:created_at).last
    unless purchase
      return render json: { error: "No pending Coinflow purchase — click Buy 1 entry first." }, status: :not_found
    end

    # The subtotal we set server-side at checkout-link time — exactly what a real
    # Settled event echoes back, so capture_matches? validates the same invariant.
    event = { "subtotal" => { "cents" => purchase.price_cents, "currency" => "USD" } }
    unless purchase.capture_matches?(event)
      return render json: { error: "Simulated amount didn't match the pack." }, status: :unprocessable_entity
    end

    Coinflow::Fulfillment.enqueue_mint!(purchase, payment_id: "sim_#{SecureRandom.hex(8)}")
    render json: {
      simulated: true,
      reference: purchase.coinflow_reference,
      message: "Settlement simulated — your entry token is minting on-chain now."
    }
  end

  # Dev/QA only (not drawn in production): stand in for Aeropay's
  # `transaction_completed` webhook, which can't reach a localhost stack. Drives
  # the SAME money-path components the real webhook uses —
  # AeropayPurchase#capture_matches? + Aeropay::Fulfillment.enqueue_mint! (the
  # exactly-once CAS + mint) — just without the HMAC HTTP hop. Mirrors the
  # coinflow_simulate_settle affordance.
  def aeropay_simulate_settle
    return head :not_found if Rails.env.production?

    purchase = current_user.aeropay_purchases.where(status: "pending").order(:created_at).last
    unless purchase
      return render json: { error: "No pending Aeropay purchase — click Buy 1 entry first." }, status: :not_found
    end

    # The pack amount as decimal dollars — exactly what a real
    # `transaction_completed` payload echoes back, so capture_matches? validates
    # the same invariant. [FLAG] amount shape assumed (see AeropayPurchase).
    event = { "amount" => Aeropay::Client.dollars_string(purchase.price_cents), "currency" => "USD" }
    unless purchase.capture_matches?(event)
      return render json: { error: "Simulated amount didn't match the pack." }, status: :unprocessable_entity
    end

    transaction_id = purchase.aeropay_transaction_id.presence || "sim_#{SecureRandom.hex(8)}"
    Aeropay::Fulfillment.enqueue_mint!(purchase, transaction_id: transaction_id)
    render json: {
      simulated: true,
      reference: purchase.aeropay_reference,
      message: "Settlement simulated — your entry token is minting on-chain now."
    }
  end

  def processing
    @session_id = params[:session_id].to_s
    # Gallery preview (/admin/modals) renders this page in a forced state via
    # ?preview_state=loading|ready|errored — no real session, so it must NOT
    # redirect to /tokens/buy (which loaded a full app page in every preview
    # iframe and stalled the gallery). Non-production only. The view's Alpine
    # component short-circuits polling/window.close when previewState is set.
    @preview_state = params[:preview_state].to_s.presence unless Rails.env.production?
    redirect_to tokens_buy_path and return if @preview_state.blank? && @session_id.blank?
    # When checkout carried a contest, return the buyer there once tokens mint.
    @contest = Contest.find_by(slug: params[:contest].presence)
    # Fallback CTA for the standalone success card: send the buyer to
    # the current "main" open contest (lowest rank). Falls back to the
    # most-recent contest, then to the contests index, all so the
    # success card always has a working "Enter contest" link.
    @next_contest = Contest.target ||
                    Contest.where(status: :open).order(created_at: :desc).first
  end

  # Polls a purchase by Stripe session_id OR PayPal order_id — the existing
  # polling UI works unchanged for either provider (both models expose
  # status / tx_signatures via MintablePurchase).
  def status
    session_id        = params[:session_id].to_s
    order_id          = params[:order_id].to_s
    reference         = params[:reference].to_s
    aeropay_reference = params[:aeropay_reference].to_s

    if session_id.present?
      purchase = current_user.stripe_purchases.for_session(session_id).first
      ref = "session=#{session_id[0, 12]}…"
    elsif order_id.present?
      purchase = current_user.paypal_purchases.for_order(order_id).first
      ref = "order=#{order_id[0, 12]}…"
    elsif reference.present?
      purchase = current_user.coinflow_purchases.for_reference(reference).first
      ref = "coinflow=#{reference[0, 16]}…"
    elsif aeropay_reference.present?
      purchase = current_user.aeropay_purchases.for_reference(aeropay_reference).first
      ref = "aeropay=#{aeropay_reference[0, 16]}…"
    else
      return render json: { ready: false }, status: :bad_request
    end

    # Bypass the entry-tokens cache for polling: we're specifically watching
    # for a brand-new on-chain mint, and Helius's getProgramAccounts indexer
    # can lag a few hundred ms behind a confirmed mint TX. If TokenPurchaseJob's
    # bust runs before the index catches up, a 0-token fetch lands in the cache
    # for 60s and the modal renders "0 available" even though the token exists
    # on chain (see screenshot test on 2026-05-27).
    current_user.bust_entry_tokens_cache!

    payload = {
      ready: purchase&.status == "minted",
      minted: purchase&.tx_signatures&.length.to_i,
      balance: current_user.entry_token_balance
    }
    # Tagged log so polling visibility is easy to grep. Pairs with the
    # client-side [tokens] pollTokenStatus logs in the board partial —
    # together they show the full handoff chain from the provider-return
    # path through to the in-modal minted state.
    Rails.logger.info "[tokens] status user=#{current_user.id} #{ref} " \
                      "purchase_status=#{purchase&.status.inspect} → #{payload.inspect}"
    render json: payload
  end

  # Dev-only helper: mint tokens directly on-chain with source="dev" instead of going through Stripe.
  def dev_mint
    pack_id = params[:pack].to_s
    unless StripePurchase.available_packs.key?(pack_id)
      return redirect_to tokens_buy_path, alert: "Unknown or unavailable token pack"
    end
    quantity = StripePurchase.pack_quantity(pack_id)

    rescue_and_log(target: current_user) do
      vault = Solana::Vault.new
      quantity.times do |i|
        vault.mint_entry_token(
          wallet_address: current_user.solana_address,
          source: :operator,
          source_ref: "dev:#{SecureRandom.hex(4)}:#{i}"
        )
      end
      redirect_to tokens_buy_path, notice: "Minted #{quantity} test token#{'s' if quantity != 1} on-chain."
    end
  rescue StandardError => e
    redirect_to tokens_buy_path, alert: "Dev mint failed: #{e.message}"
  end

  private

  # Order CREATION is double-gated: the operator flag (PAYMENT_PROVIDER) AND
  # configured credentials. Either off → paypal_order refuses, so this branch
  # deploys inert until the operator flips the flag post-approval (no
  # PaypalPurchase row can exist without it, so paypal_capture 404s too).
  # paypal_capture and the webhook are deliberately NOT flag-gated: after a
  # rollback to stripe, in-flight approved orders must still drain — see
  # docs/PAYPAL_VENMO.md "Heroku flip".
  def paypal_checkout_enabled?
    Payments.paypal_checkout?
  end

  def require_login
    return if logged_in?
    # JS pollers (e.g. /tokens/status) hit this with Accept: application/json
    # after a session lapse. Without the format branch we'd 302 → /login,
    # the fetch would follow it, and SessionsController#new would 500 on
    # the missing JSON template. Mirror ApplicationController#require_authentication.
    respond_to do |format|
      format.html { redirect_to signin_path, alert: "Please sign in to buy entry tokens." }
      format.json { render json: { error: "unauthenticated" }, status: :unauthorized }
      format.any  { head :unauthorized }
    end
  end

  def require_dev_mint_allowed
    # OPSEC-020: triple gate — admin AND devnet config AND non-production Rails
    # env. dev_mint mints real on-chain entry tokens for free; one
    # mis-configured env var (or one stolen admin session) on mainnet would
    # be unlimited free tokens. The route should also be removed from
    # config/routes.rb when Rails.env.production?; this is defense-in-depth.
    return if current_user&.admin? && Solana::Config.devnet? && !Rails.env.production?
    redirect_to tokens_buy_path, alert: "Dev mint is admin + devnet only."
  end
end
