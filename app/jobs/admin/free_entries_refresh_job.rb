module Admin
  # Warms the free-entries admin table's render caches OFF the request path.
  #
  # Admin::FreeEntriesController renders CACHE-FIRST (no Solana RPC on the render
  # path). When a listed user's on-chain data is cold, the controller enqueues
  # this job with the cold user ids; it does the blocking reads and writes the
  # SAME caches the render reads, so the next page render is a warm hit.
  #
  # For each user:
  #   - sync_balance → update_level_from_seeds! refreshes the denormalized
  #     users.seeds/level mirror the table shows for seeds/level.
  #   - list_entry_tokens WRITES entry_tokens:<address> (the key the render reads
  #     via Solana::Vault.entry_tokens_cache_key), warming minted/unconsumed.
  #
  # Individually nil-safe: an RPC flake on one user is logged and skipped, never
  # failing the whole batch.
  class FreeEntriesRefreshJob < ApplicationJob
    queue_as :default

    def perform(user_ids)
      User.where(id: user_ids).find_each do |user|
        address = user.solana_address
        next if address.blank?

        refresh_user(user, address)
      end
    end

    private

    def refresh_user(user, address)
      vault = Solana::Vault.new

      seeds = vault.sync_balance(address)&.dig(:seeds)
      user.update_level_from_seeds!(seeds) unless seeds.nil?

      # WRITES entry_tokens:<address> — the same cache the render reads
      # cache-first (Solana::Vault#list_entry_tokens wraps a 60s Rails.cache).
      vault.list_entry_tokens(address)
    rescue => e
      Rails.logger.warn("[free-entries-refresh] user=#{user.id} refresh failed: #{e.message}")
    end
  end
end
