class FaucetController < ApplicationController
  skip_before_action :require_authentication

  def show
    @recent_claims = TransactionLog.where(transaction_type: "faucet")
                                   .order(created_at: :desc)
                                   .limit(10)
                                   .includes(:user)
    # Bottom-CTA target — prefer the admin-set main contest (set via
    # /admin/dashboard), then fall back to the oldest open contest.
    @contest = SeasonConfig.main_contest ||
               Contest.where(status: "open").order(created_at: :asc).first
  end

  def claim
    unless logged_in?
      return render json: { success: false, error: "Please log in to claim test USDC." }, status: :unauthorized
    end

    # Dollars in, whole cents out, through BigDecimal: `2.01.to_f * 100` is
    # 200.99999999999997, which `to_i` would mint as $2.00.
    requested = BigDecimal(params[:amount].to_s, exception: false)
    amount_cents = requested ? (requested * 100).floor.to_i : 0
    amount_dollars = BigDecimal(amount_cents) / 100

    unless amount_cents > 0 && amount_cents <= 500_00
      return render json: { success: false, error: "Amount must be between $1 and $500." }, status: :unprocessable_entity
    end

    rescue_and_log(target: current_user) do
      # OPSEC-020: defense-in-depth. Solana::Config.devnet? reads SOLANA_NETWORK
      # env, which can be misconfigured. Belt-and-suspenders the Rails env —
      # via AppFlags.live_production?, which excludes QA apps (they boot as
      # Rails production but are devnet review targets that need the faucet).
      raise "Faucet is production-disabled" if AppFlags.live_production?
      raise "Faucet only available on Devnet" unless Solana::Config.devnet?
      raise "No Solana wallet connected" unless current_user.solana_connected?

      vault = Solana::Vault.new
      wallet = current_user.solana_address

      vault.ensure_ata(wallet, mint: Solana::Config::USDC_MINT)
      amount_lamports = Solana::Config.cents_to_base_units(amount_cents)
      result = vault.mint_spl(amount_lamports, mint: Solana::Config::USDC_MINT, to: wallet)

      invalidate_usdc_cache
      TransactionLog.record!(
        user: current_user,
        type: "faucet",
        amount_cents: amount_cents,
        direction: "credit",
        description: "Devnet faucet $#{'%.2f' % amount_dollars}",
        onchain_tx: result[:signature]
      )
      render json: { success: true, tx: result[:signature], amount: amount_dollars.to_s("F") }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end
end
