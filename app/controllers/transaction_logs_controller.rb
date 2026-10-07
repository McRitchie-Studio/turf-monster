class TransactionLogsController < ApplicationController
  before_action :require_admin

  def index
    @transaction_logs = TransactionLog.includes(:user, :source).order(created_at: :desc)
    @transaction_logs = @transaction_logs.by_type(params[:type]) if params[:type].present?
    @transaction_logs = @transaction_logs.where(status: params[:status]) if params[:status].present?
    @transaction_logs = @transaction_logs.where(user_id: params[:user_id]) if params[:user_id].present?
    @transaction_logs = @transaction_logs.limit(100)

    @summary = {
      total_deposits: TransactionLog.by_type("deposit").completed.sum(:amount_cents),
      total_withdrawals: TransactionLog.by_type("withdrawal").completed.sum(:amount_cents),
      total_payouts: TransactionLog.by_type("payout").completed.sum(:amount_cents),
      total_entry_fees: TransactionLog.by_type("entry_fee").completed.sum(:amount_cents),
      pending_count: TransactionLog.pending.count
    }
  end

  def show
    @transaction_log = TransactionLog.find_by(slug: params[:slug])
    return redirect_to admin_transactions_path, alert: "Transaction not found" unless @transaction_log
  end

  # v0.16: the `withdraw` on-chain instruction has been removed alongside
  # the custodial-balance model. Managed-wallet USDC now lives in the user's
  # own ATA — there's no pooled vault balance to debit. The replacement is
  # an off-chain payout flow handled by the operator (Kraken/Coinbase + bank
  # wire / Zelle).
  #
  # This action becomes an operator-handoff stub: it flips the TransactionLog
  # to "approved" so it appears in the admin "needs payout" queue, but does
  # NOT execute an on-chain TX. The operator processes the off-ramp manually,
  # then clicks "Complete" (the existing :complete action) to mark fiat-sent.
  #
  # Phase 2 task (separate engagement): replace this stub with a proper
  # PayoutRequest model + Stripe Connect/Zelle/Kraken integration. The
  # TransactionLog row's metadata is the audit trail for that work.
  def approve
    txn = TransactionLog.find_by(slug: params[:slug])
    return redirect_to admin_transactions_path, alert: "Transaction not found" unless txn

    rescue_and_log(target: txn) do
      txn.with_lock do
        raise "Only pending transactions can be approved" unless txn.status == "pending"

        # OPSEC-031: re-check balance at approve time. The user's USDC ATA
        # may have drained between request submission and approval (e.g.
        # the user spent USDC entering a contest in between).
        # Compared in base units, both sides integers.
        amount_dollars = BigDecimal(txn.amount_cents) / 100
        onchain = Solana::Vault.new.sync_balance(txn.user.solana_address)
        available = onchain&.dig(:balance).to_i
        if Solana::Config.cents_to_base_units(txn.amount_cents) > available
          raise "Withdrawal exceeds current ATA balance (#{helpers.dollars(Solana::Config.base_units_to_dollars(available))} available; user may have spent down since request)"
        end

        # No on-chain TX — operator off-ramps via Kraken/Coinbase + wires
        # the user via Zelle. Phase 2 will plumb this through a PayoutRequest
        # model with proper status tracking.
        new_description = "#{txn.description} (operator off-ramp queued)"
        txn.update!(status: "approved", description: new_description)

        Rails.logger.warn("[v0.16-payout] manual operator action required: " \
          "TransactionLog ##{txn.id} (#{txn.slug}) for user=#{txn.user.id} " \
          "amount=$#{format('%.2f', amount_dollars)} — process off-ramp manually, " \
          "then mark complete at /admin/transactions/#{txn.slug}/complete")
      end
      redirect_to admin_transactions_path(status: "pending"),
                  notice: "Withdrawal queued for off-ramp (operator handles manually). " \
                          "Mark complete after wire confirms."
    end
  rescue StandardError => e
    redirect_to admin_transactions_path, alert: "Approve failed: #{e.message}"
  end

  def complete
    txn = TransactionLog.find_by(slug: params[:slug])
    return redirect_to admin_transactions_path, alert: "Transaction not found" unless txn

    rescue_and_log(target: txn) do
      raise "Only approved transactions can be completed" unless txn.status == "approved"
      txn.update!(status: "completed", description: "#{txn.description} (fiat sent)")
      redirect_to admin_transactions_path, notice: "Withdrawal marked complete for #{txn.user.display_name}."
    end
  rescue StandardError => e
    redirect_to admin_transactions_path, alert: "Complete failed: #{e.message}"
  end

  def deny
    txn = TransactionLog.find_by(slug: params[:slug])
    return redirect_to admin_transactions_path, alert: "Transaction not found" unless txn

    rescue_and_log(target: txn) do
      raise "Only pending transactions can be denied" unless txn.status == "pending"
      # No DB refund needed — balance is on-chain. Just mark as denied.
      txn.update!(status: "failed", description: "#{txn.description} (denied)")
      redirect_to admin_transactions_path(status: "pending"), notice: "Withdrawal denied for #{txn.user.display_name}."
    end
  rescue StandardError => e
    redirect_to admin_transactions_path, alert: "Deny failed: #{e.message}"
  end
end
