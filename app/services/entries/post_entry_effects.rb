module Entries
  # What follows a confirmed entry, whichever surface made it: read the seeds
  # the entry earned, nudge the level-up token mint, write the `[entry][confirmed]`
  # log line, and drop the navbar caches the spend made stale.
  #
  # Lifted from ContestsController#post_entry_seeds_payload so an entry made
  # through the agent API earns its level-up token and refreshes the player's
  # navbar exactly as one made in the browser does. Returns the seeds triple the
  # browser's success response carries.
  #
  # Every chain read here is best-effort: the entry is already confirmed, and a
  # seeds read that flakes must not turn a paid entry into an error.
  class PostEntryEffects
    def self.call(entry:, user:, contest:, path:, tx_signature:, token_consumed: nil)
      seeds_earned = 0
      seeds_total  = 0
      seeds_level  = 0
      verified_seeds_total = nil

      if entry.onchain_tx_signature.present? && entry.entry_number.present?
        begin
          seeds_earned = Solana::Vault.new.seeds_for_entry(entry.entry_number)
        rescue => e
          Rails.logger.warn "Failed to read seeds_for_entry: #{e.message}"
        end
        if user.solana_connected?
          begin
            onchain = Solana::Vault.new.sync_balance(user.solana_address)
            verified_seeds_total = onchain&.dig(:seeds)
            seeds_total = verified_seeds_total || 0
          rescue => e
            Rails.logger.warn "Failed to read seeds after entry: #{e.message}"
          end
        end
        seeds_level = User.level_for(seeds_total)
        LevelUpTokenMintJob.nudge(user, seeds_total: verified_seeds_total) if verified_seeds_total
      end

      tx_prefix = tx_signature.to_s.first(8)
      token_part = token_consumed.nil? ? "" : " token_consumed=#{token_consumed}"
      Rails.logger.info(
        "[entry][confirmed] path=#{path} user_id=#{user.id} " \
        "entry_id=#{entry.id} contest=#{contest.slug} tx=#{tx_prefix}... " \
        "seeds_earned=#{seeds_earned} seeds_total=#{seeds_total} " \
        "seeds_level=#{seeds_level}#{token_part}"
      )

      # BOTH balance keys, not just USDC: a Phantom entry may have spent USDT
      # (ContestsController#prepare_entry maps currency "usdt" to currency_idx 1),
      # in which case a one-key drop would clear the key that did NOT move and
      # keep the stale pre-spend balance that did.
      NavbarCacheKeys.after_entry(user).each { |key| Rails.cache.delete(key) } if user.solana_connected?

      { seeds_earned: seeds_earned, seeds_total: seeds_total, seeds_level: seeds_level }
    end
  end
end
