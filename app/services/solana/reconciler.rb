module Solana
  class Reconciler
    attr_reader :vault, :discrepancies

    def initialize
      @vault = Vault.new
      @discrepancies = []
    end

    # Verify user has an on-chain USDC account
    def reconcile_user(user)
      return unless user.solana_connected?

      onchain = vault.sync_balance(user.solana_address)
      unless onchain
        @discrepancies << {
          type: :missing_onchain_account,
          user_id: user.id,
          user_name: user.display_name,
          solana_address: user.solana_address
        }
        return
      end

      onchain
    end

    # Reconcile all users with Solana addresses
    def reconcile_all
      @discrepancies = []
      users = User.where.not(solana_address: nil)
      results = {}

      users.find_each do |user|
        results[user.id] = reconcile_user(user)
      rescue => e
        @discrepancies << {
          type: :error,
          user_id: user.id,
          user_name: user.display_name,
          error: e.message
        }
      end

      log_discrepancies if @discrepancies.any?
      { users_checked: users.count, discrepancies: @discrepancies }
    end

    # Verify onchain contest state matches DB. v0.16 Contest layout has
    # per-currency entry_fee_by_currency + entry_fees arrays — for the
    # USDC-only Phase 1 we reconcile against slot 0 (USDC) totals.
    def reconcile_contest(contest)
      return unless contest.onchain?

      onchain = vault.read_contest(contest.slug)
      unless onchain
        @discrepancies << {
          type: :missing_onchain_contest,
          contest_id: contest.id,
          contest_name: contest.name,
          onchain_id: contest.onchain_contest_id
        }
        return
      end

      current_entries = onchain[:current_entries]
      slot0_fees       = onchain[:entry_fees].is_a?(Array) ? onchain[:entry_fees][0].to_i : 0
      slot0_fee        = onchain[:entry_fee_by_currency].is_a?(Array) ? onchain[:entry_fee_by_currency][0].to_i : 0

      db_entries = contest.entries.where(status: [:active, :complete]).count
      db_pool    = Solana::Config.cents_to_base_units(contest.pool_cents)

      if current_entries.to_i != db_entries
        @discrepancies << {
          type: :entry_count_mismatch,
          contest_id: contest.id,
          contest_name: contest.name,
          db_entries: db_entries,
          onchain_entries: current_entries
        }
      end

      if slot0_fees != db_pool
        @discrepancies << {
          type: :entry_fees_mismatch,
          contest_id: contest.id,
          contest_name: contest.name,
          db_pool_lamports: db_pool,
          onchain_pool_lamports: slot0_fees
        }
      end

      {
        entry_fee:       slot0_fee,
        max_entries:     onchain[:max_entries],
        current_entries: current_entries,
        entry_fees:      slot0_fees,
        prize_pool:      onchain[:prize_pool]
      }
    end

    private

    def log_discrepancies
      @discrepancies.each do |d|
        Rails.logger.warn "[Solana Reconciler] #{d[:type]}: #{d.except(:type).to_json}"
        ErrorLog.create!(
          message: "Solana reconciliation: #{d[:type]}",
          inspect: d.to_json,
          backtrace: caller.first(5).to_json
        )
      end
    end
  end
end
