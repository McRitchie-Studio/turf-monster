class WalletsController < ApplicationController
  before_action :require_login
  before_action :require_geo_allowed, only: [:withdraw, :stripe_deposit]
  # B4 / OPSEC-048: frozen accounts can view the wallet page but cannot move money.
  before_action :require_unfrozen_account, only: [:withdraw, :stripe_deposit]

  def show
    @user = current_user
    @pending_withdrawals = TransactionLog.where(user: current_user, transaction_type: "withdrawal", status: %w[pending approved]).order(created_at: :desc)
    @recent_transactions = TransactionLog.where(user: current_user).order(created_at: :desc).limit(10)

    # /wallet is a specific page where a blocking balance read is expected —
    # the navbar preload no longer populates @wallet_balances (it renders
    # cache-first now), so this page fetches its own. This also populates
    # @wallet_balances[:usdc] so display_balance returns it for the on-page
    # balance card without a second read. Devnet-only SOL display gate
    # preserved. Fail-safe to nil so the view falls back to its own JS sync.
    load_wallet_balances
  end

  def stripe_deposit
    amount_dollars = params[:amount].to_f
    return redirect_to wallet_path, alert: "Amount must be between $1 and $500" unless amount_dollars >= 1 && amount_dollars <= 500

    amount_cents = (amount_dollars * 100).to_i

    rescue_and_log(target: current_user) do
      session = Stripe::Checkout::Session.create(
        payment_method_types: ["card"],
        line_items: [{
          price_data: {
            currency: "usd",
            product_data: { name: "Turf Monster Deposit" },
            unit_amount: amount_cents
          },
          quantity: 1
        }],
        mode: "payment",
        success_url: "#{wallet_url}?deposit=success",
        cancel_url: "#{wallet_url}?deposit=cancelled",
        metadata: {
          # OPSEC-008: explicit kind so StripeCheckoutValidator's kind_mismatch
          # check passes (validator routes on metadata["kind"] == @kind).
          # Without this, every deposit webhook would 422 on :kind_mismatch.
          kind: "deposit",
          user_id: current_user.id,
          amount_cents: amount_cents,
          wallet_address: current_user.solana_address
        }
      )

      redirect_to session.url, allow_other_host: true
    end
  rescue StandardError => e
    redirect_to wallet_path, alert: "Stripe checkout failed: #{e.message}"
  end

  def withdraw
    # OPSEC-046: an impersonating admin must never move a user's funds. Hard
    # stop, even though the impersonated session is web2 (no Phantom signature)
    # and couldn't complete a self-custodied withdraw anyway — defense in depth.
    return redirect_to account_path, alert: "Withdrawals are disabled while acting as another user." if impersonating?

    amount_dollars   = params[:amount].to_f
    destination_info = params[:destination_info].to_s.strip
    return redirect_to wallet_path, alert: "Invalid amount" if amount_dollars <= 0
    return redirect_to wallet_path, alert: "Tell us where to send your money."  if destination_info.blank?
    return redirect_to wallet_path, alert: "Destination info too long (max 500 chars)." if destination_info.length > 500

    amount_cents = (amount_dollars * 100).to_i

    rescue_and_log(target: current_user) do
      raise "No wallet connected" unless current_user.solana_connected?

      # Self-custodied users hold their own key — the server can't sign for
      # them, so an off-ramp service we'd integrate (Stripe / Bridge / etc.)
      # has no funding source to draw against. Point them at the wallet
      # they exported into instead. See task #11 + WalletExportsController.
      if current_user.self_custodied?
        raise "Your wallet is self-custodied. Send USDC directly from the wallet you imported it into."
      end

      # OPSEC-031: cap at on-chain balance at request time. Previously the
      # action accepted any params[:amount] and an admin approving the
      # queue would have triggered an on-chain withdraw against insufficient
      # funds (either bouncing the TX with rent cost, or — for the bot's
      # ATA — draining the bot). The :approve action re-checks too.
      onchain = Solana::Vault.new.sync_balance(current_user.solana_address)
      available_dollars = onchain&.dig(:balance_dollars).to_f
      if amount_dollars > available_dollars
        raise "Withdrawal exceeds on-chain balance ($#{format('%.2f', available_dollars)} available)"
      end

      # Store the operator-facing routing info in metadata. Stage 1
      # (now): operator reads this off the admin transaction-log page
      # and processes the off-ramp manually (Kraken/Bridge/Stripe).
      # Stage 2 (separate engagement): a Bridge::Withdrawal (or Stripe
      # Connect equivalent) service consumes these rows + signs the
      # on-chain SPL transfer from the user's managed-wallet ATA to
      # the off-ramp provider's deposit address.
      TransactionLog.record!(
        user: current_user,
        type: "withdrawal",
        amount_cents: amount_cents,
        direction: "debit",
        description: "Withdrawal request $#{'%.2f' % amount_dollars}",
        status: "pending",
        metadata: {
          destination_info: destination_info,
          requested_at: Time.current.iso8601,
          requested_from_ip: request.remote_ip
        }
      )
      redirect_to wallet_path, notice: "Withdrawal of $#{'%.2f' % amount_dollars} submitted for review. We'll email you when funds are sent."
    end
  rescue StandardError => e
    redirect_to wallet_path, alert: "Withdrawal failed: #{e.message}"
  end

  def faucet
    rescue_and_log(target: current_user) do
      raise "Faucet is production-disabled" if AppFlags.live_production?  # OPSEC-020
      raise "Faucet only available on Devnet" unless Solana::Config.devnet?
      raise "No wallet connected" unless current_user.solana_connected?

      vault = Solana::Vault.new
      amount_lamports = Solana::Config.dollars_to_lamports(10.0) # $10 USDC
      vault.ensure_ata(current_user.solana_address, mint: Solana::Config::USDC_MINT)
      result = vault.fund_user(current_user.solana_address, amount_lamports)

      TransactionLog.record!(user: current_user, type: "faucet", amount_cents: 10_00, direction: "credit", description: "Devnet faucet $10.00", onchain_tx: result[:signature])
      invalidate_usdc_cache
      redirect_to wallet_path, notice: "Added $10.00 test USDC to your balance."
    end
  rescue StandardError => e
    redirect_to wallet_path, alert: "Faucet failed: #{e.message}"
  end

  def airdrop
    rescue_and_log(target: current_user) do
      raise "Airdrop is production-disabled" if AppFlags.live_production?  # OPSEC-020
      raise "Airdrop only available on Devnet" unless Solana::Config.devnet?
      raise "No Solana wallet connected" unless current_user.solana_connected?

      client = Solana::Config.client
      signature = client.request_airdrop(current_user.solana_address, 1_000_000_000) # 1 SOL
      redirect_to wallet_path, notice: "Airdropped 1 SOL! TX: #{signature}"
    end
  rescue StandardError => e
    redirect_to wallet_path, alert: "Airdrop failed: #{e.message}"
  end

  def sync
    rescue_and_log(target: current_user) do
      unless current_user.solana_connected?
        return redirect_to wallet_path, alert: "No Solana wallet connected."
      end

      vault = Solana::Vault.new
      onchain = vault.sync_balance(current_user.solana_address)

      if onchain
        @onchain_balance = onchain
        flash.now[:notice] = "Onchain balance: $#{'%.2f' % onchain[:balance_dollars]}"
      else
        flash.now[:alert] = "No onchain account found. Deposit to create one."
      end

      @user = current_user
      @pending_withdrawals = TransactionLog.where(user: current_user, transaction_type: "withdrawal", status: %w[pending approved]).order(created_at: :desc)
      @recent_transactions = TransactionLog.where(user: current_user).order(created_at: :desc).limit(10)
      load_wallet_balances
      render :show
    end
  rescue StandardError => e
    redirect_to wallet_path, alert: "Sync failed: #{e.message}"
  end

  private

  # Explicit blocking balance fetch for the /wallet page (show + sync). Sets
  # @wallet_balances (so display_balance reuses it) + @sol_balance (devnet
  # display). Best-effort: nil on flake, and the view's own x-init JS sync
  # backfills the USDC display.
  def load_wallet_balances
    return unless current_user.solana_connected?

    @wallet_balances = Solana::Vault.new.fetch_wallet_balances(current_user.solana_address)
    if Solana::Config.devnet? && @wallet_balances.is_a?(Hash) && @wallet_balances.key?(:sol)
      @sol_balance = @wallet_balances[:sol]
    end
  rescue => e
    Rails.logger.warn("[wallet] fetch_wallet_balances failed: #{e.message}")
    @wallet_balances = nil
  end

  def require_login
    return if logged_in?
    # Wallet polling (sync, balance refresh) carries Accept: application/json
    # after a session lapse; an unconditional redirect would 302 → /login
    # which has no JSON template. Mirror ApplicationController#require_authentication.
    respond_to do |format|
      format.html { redirect_to signin_path, alert: "Please sign in to access your wallet." }
      format.json { render json: { error: "unauthenticated" }, status: :unauthorized }
      format.any  { head :unauthorized }
    end
  end
end
