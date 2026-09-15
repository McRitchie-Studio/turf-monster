module EntryGifts
  # Would linking a self-custody wallet strand a free entry this account still
  # holds?
  #
  # THE FAULT THIS EXISTS TO REFUSE. User#solana_address resolves as
  # `web3_solana_address || web2_solana_address` — Phantom wins, unconditionally.
  # A gifted player is given a MANAGED wallet at claim time (EntryGifts::Claim
  # #ensure_wallet!, which runs inside the claim lock) and the voucher is minted
  # on chain at that address, where it cannot be moved. So the moment that same
  # account links a Phantom, #solana_address stops resolving to the wallet the
  # voucher lives in, and every entry path that reads it looks straight past a
  # token the account genuinely owns.
  #
  # The voucher is not lost — it is STRANDED, which is worse, because from the
  # player's side a free entry they were given has silently become someone
  # else's. The account is left in the both-wallets state User#combo_wallets?
  # already names; nothing consulted it here.
  #
  # MEASURED, not reasoned: claim a gift on a fresh account, link a Phantom, and
  # #solana_address flips off the stamped address with combo_wallets? true and
  # WalletSetupPolicy.required? false — nothing anywhere notices. Pinned by
  # test/services/entry_gifts/unspent_voucher_test.rb.
  #
  # THE UNSPENT WINDOW HAS TWO HALVES, and the second is the one a token-only
  # read misses — the same seam WalletSetupPolicy#holds_free_entry? was written
  # for. The claim is SYNCHRONOUS and EntryGiftMintJob is not, so between the
  # two there is a live gift with no token on chain to find. A guard that only
  # asked the chain would wave the wallet link through in exactly that window
  # and strand the voucher it was written to protect.
  class UnspentVoucher
    # Why the link is refused, carried alongside the gift so the caller can say
    # the honest sentence rather than one message for two different facts.
    # :unspent — we read the voucher and it is still there.
    # :unknown — we could not read it, and that is not permission to proceed.
    Blocker = Struct.new(:gift, :reason, keyword_init: true) do
      def unknown? = reason == :unknown
    end

    # The Blocker a wallet link would earn, or nil when the link is safe.
    def self.blocking_for(user, vault: nil) = new(user, vault: vault).blocking

    # `vault:` injected the same way WalletSetupPolicy takes it, and for the
    # same reason: the RPC is the only I/O here, so a test that cannot replace
    # it can only assert the halves that never reach the chain.
    def initialize(user, vault: nil)
      @user = user
      @vault = vault
    end

    def blocking
      return nil if user.blank?
      # Already web3: #solana_address resolves to the Phantom either way, so
      # this link moves nothing. (A wallet SWITCH lands here too — swapping one
      # Phantom for another cannot strand a MANAGED voucher any further than
      # the first link already did.)
      return nil if user.phantom_wallet?

      managed = user.web2_solana_address
      return nil if managed.blank?

      # Scoped to gifts stamped at the managed address, because those are
      # exactly the ones #solana_address resolves to today and would stop
      # resolving to. `mint_error` blank keeps a gift that can never be paid
      # (an admin claimant, OPSEC-044) from blocking a wallet link forever.
      EntryGift.where(claimed_by: user, mint_error: nil, wallet_address: managed)
               .where.not(claimed_at: nil)
               .filter_map { |gift|
                 reason = still_held?(gift)
                 Blocker.new(gift: gift, reason: reason) unless reason == :spent
               }.first
    end

    private

    attr_reader :user

    # :unspent · :spent · :unknown — and the caller blocks on anything but
    # :spent.
    #
    # FAILS CLOSED, unlike User#next_unconsumed_entry_token_for, which rescues
    # to nil and so cannot tell "no token" from "could not read". That
    # distinction is the whole guard: an RPC flake read as "spent" disarms it
    # silently, and the cost of that direction is permanent — a stranded voucher
    # cannot be moved once minted. The other direction costs a retry. So a read
    # that fails is treated as a voucher still held, and the caller says so.
    def still_held?(gift)
      return :unspent if gift.minted_at.blank? # claimed; mint still queued

      tokens = (@vault || Solana::Vault.new).list_entry_tokens(gift.wallet_address)
      tokens.any? { |token| !token[:consumed] } ? :unspent : :spent
    rescue StandardError => e
      Rails.logger.warn("[entry-gift] voucher read failed user=#{user.id} " \
                        "gift=#{gift.id}: #{e.class}: #{e.message}")
      :unknown
    end
  end
end
