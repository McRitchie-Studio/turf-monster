# Mints the on-chain entry token an EntryGift promised, once the recipient has
# clicked their invite and therefore has an address.
#
# WHY THE MINT IS NOT IN THE REQUEST. EntryGifts::Claim runs while the recipient
# is mid-sign-in; a mint is an RPC round trip plus confirmation, and the person
# is waiting on a page. So the claim writes the row and this job pays it.
#
# SAFE TO RUN TWICE, AND SAFE TO RETRY AFTER A LOST RESPONSE — the two are
# different problems and both are handled here:
#
#   - A repeat while the first is in flight, or after it succeeded, sees
#     minted_at inside the row lock and returns.
#   - A retry after a mint that LANDED but whose response never came back is the
#     harder one, and the reason #recover_landed_mint exists. EntryGift#mint_
#     source_ref is deterministic, so the retry re-derives the same PDA and the
#     program's `init` REFUSES it. That refusal is indistinguishable from a real
#     failure by its error alone — so on any mint failure this job asks the
#     chain whether a token carrying this gift's ref is already there, and
#     stamps the gift from that reading rather than erroring forever.
#
# The recipient's cached token list is busted on success, because they are very
# likely looking at the page whose badge reads it.
class EntryGiftMintJob < ApplicationJob
  queue_as :default

  def perform(gift_id)
    gift = EntryGift.find_by(id: gift_id)
    return if gift.nil? || gift.minted?

    address = gift.wallet_address.presence || gift.claimed_by&.solana_address
    return record_unpayable(gift) if address.blank?

    # Catches a stale Sidekiq env pointing at a dead PROGRAM_ID — the
    # mint-to-wrong-program failure that has bitten twice on devnet redeploys.
    # Same guard, same reason, as LevelUpTokenMintJob.
    Solana::Vault.ensure_program_id_live! unless ENV["SKIP_PROGRAM_ID_LIVE_CHECK"] == "true"

    mint!(gift, address)
  end

  private

  def mint!(gift, address)
    vault = Solana::Vault.new

    gift.with_lock do
      # Re-read under the lock: a concurrent run may have paid it since the
      # check above.
      return if gift.reload.minted?

      result = vault.mint_entry_token(wallet_address: address, source: :operator,
                                      source_ref: gift.mint_source_ref)
      stamp_minted(gift, address, result[:signature])
    end

    gift.claimed_by&.bust_entry_tokens_cache!
    Rails.logger.info "[entry-gift] minted gift=#{gift.id} to=#{address} sig=#{gift.mint_signature}"
  rescue StandardError => e
    # The lost-response case: ask the chain before believing the error.
    if (signature = recover_landed_mint(gift, address, vault))
      stamp_minted(gift, address, signature)
      gift.claimed_by&.bust_entry_tokens_cache!
      Rails.logger.info "[entry-gift] recovered gift=#{gift.id} — token already on chain"
      return
    end

    gift.update_columns(mint_error: "#{e.class}: #{e.message.to_s.first(300)}",
                        updated_at: Time.current)
    Rails.logger.warn "[entry-gift] mint_failed gift=#{gift.id} (#{e.class}: #{e.message.to_s[0, 140]})"
    raise
  end

  def stamp_minted(gift, address, signature)
    gift.update!(minted_at: Time.current, mint_signature: signature,
                 wallet_address: address, mint_error: nil)
  end

  # Is a token carrying THIS gift's source_ref already on chain? Returns its
  # signature-shaped stand-in (the PDA) when so, nil otherwise.
  #
  # The PDA and not a real transaction signature, because the signature of a
  # confirmation we never received is not recoverable — and the PDA is the more
  # useful identifier anyway: it is what the ref derives and what the burn path
  # addresses. #mint_signature is an audit handle, not a replay input.
  #
  # A failure to READ is not a failure to MINT: if this lookup itself raises,
  # return nil so the caller records the original error and Sidekiq retries.
  def recover_landed_mint(gift, address, vault)
    return nil if address.blank?

    ref = gift.mint_source_ref
    token = (vault || Solana::Vault.new).list_entry_tokens(address)
                                        .find { |t| t[:source_ref].to_s == ref }
    token && (token[:pda].presence || "recovered")
  rescue StandardError => e
    Rails.logger.warn "[entry-gift] recovery_read_failed gift=#{gift.id} " \
                      "(#{e.class}: #{e.message.to_s[0, 140]})"
    nil
  end

  # A claim with no address to pay. Recorded rather than raised: retrying cannot
  # conjure a wallet, and the ledger's job is to make this visible so an operator
  # can act on it.
  def record_unpayable(gift)
    gift.update_columns(mint_error: EntryGifts::Claim::NO_WALLET_REASON,
                        updated_at: Time.current)
    Rails.logger.warn "[entry-gift] unpayable gift=#{gift.id} — no wallet address"
  end
end
