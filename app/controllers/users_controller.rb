class UsersController < ApplicationController
  before_action :require_admin, only: [:add_funds]

  def add_funds
    rescue_and_log(target: current_user) do
      # OPSEC-020: this action calls vault.fund_user (admin transfers $100 USDC
      # to the requester). Admin-only via before_action but had NO devnet
      # guard — a compromised admin account could have drained the bot on
      # mainnet. Belt-and-suspenders with both Rails.env and SOLANA_NETWORK.
      raise "add_funds is production-disabled" if AppFlags.live_production?
      raise "add_funds only available on Devnet" unless Solana::Config.devnet?
      raise "No wallet connected" unless current_user.solana_connected?

      vault = Solana::Vault.new
      amount_lamports = Solana::Config.dollars_to_lamports(100.0) # $100 USDC
      vault.ensure_ata(current_user.solana_address, mint: Solana::Config::USDC_MINT)
      result = vault.fund_user(current_user.solana_address, amount_lamports)

      TransactionLog.record!(user: current_user, type: "admin_credit", amount_cents: 100_00, direction: "credit", description: "Admin credit $100.00", onchain_tx: result[:signature])
      invalidate_usdc_cache
      redirect_back fallback_location: root_path, notice: "Added $100 to your balance."
    end
  rescue StandardError => e
    redirect_back fallback_location: root_path, alert: "Failed to add funds."
  end
end
