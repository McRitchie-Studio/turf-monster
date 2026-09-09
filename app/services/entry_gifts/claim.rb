module EntryGifts
  # Redeems an EntryGift the moment its magic link is consumed: stamps the
  # claim, makes sure the account has an address a token can land on, and hands
  # the mint to a background job.
  #
  # THIS RUNS INSIDE A SIGN-IN REQUEST, so it does no on-chain work at all. The
  # recipient is mid-click; a getProgramAccounts scan or a mint instruction here
  # would put the Solana RPC's latency between them and their first page. The
  # only writes are one row and (for a brand-new account) one keypair.
  #
  # IT NEVER CHECKS THAT THE CLICKER'S EMAIL MATCHES THE GIFT'S, and that is
  # deliberate. The link was minted FOR the recipient address and is single-use;
  # whoever holds it is signed in as that address by the consume path itself, so
  # a match check could only ever fire when the account's email was CHANGED
  # after the invite went out — stranding a legitimate gift to restate something
  # the link already guarantees.
  #
  # IDEMPOTENT. A second call (the recipient re-clicking their own live link,
  # a double-submit) sees claimed_at and returns without a second job. The real
  # double-mint guard is on chain — EntryGift#mint_source_ref — but there is no
  # reason to spend an RPC finding that out.
  class Claim
    Result = Struct.new(:claimed, :gift, :reason, keyword_init: true) do
      def claimed? = !!claimed
    end

    # Why a claim could not be paid. Both are recorded on the row so the ledger
    # can name the condition rather than showing a gift stuck at "claimed".
    NO_WALLET_REASON = "account has no Solana address and one could not be created — " \
                       "nothing to mint the entry token to".freeze
    ADMIN_REASON     = "admin accounts hold no custodial keys (OPSEC-044), so this gift " \
                       "cannot be minted to a managed wallet — link a wallet and re-mint".freeze

    def self.call(gift, user) = new(gift, user).call

    def initialize(gift, user)
      @gift = gift
      @user = user
    end

    def call
      return result(false, "no gift on this link") if @gift.blank?
      return result(false, "no user to claim for")  if @user.blank?
      return result(false, "already claimed")       if @gift.claimed?

      @gift.with_lock do
        # Re-read inside the lock: two clicks racing both passed the check above.
        return result(false, "already claimed") if @gift.reload.claimed?

        address = ensure_wallet!
        @gift.update!(claimed_by: @user, claimed_at: Time.current,
                      wallet_address: address, mint_error: unpayable_reason(address))
      end

      # OUTSIDE the lock and outside the transaction: enqueueing inside would
      # let Sidekiq pick the job up before the claim row commits, and the job
      # would then read a gift that is not claimed yet.
      EntryGiftMintJob.perform_later(@gift.id) if @gift.mint_error.blank?

      result(true, nil)
    end

    private

    # The operator's call, stated in one line: a gifted account gets a managed
    # wallet even though web3-only onboarding is on, because the gift IS an
    # on-chain token and a token needs an address. Returns the address the mint
    # should target, or nil when this account can hold no custodial key.
    #
    # IT ALSO ENQUEUES THE ON-CHAIN UserAccount, and leaving that out would have
    # been a silent half-gift. User's `after_commit :enqueue_onchain_account_setup`
    # already ran at signup, when web3-only onboarding meant the account had no
    # wallet — so CreateOnchainUserAccountJob returned on `solana_connected?` and
    # created no PDA, and nothing re-runs it when a wallet appears later. The
    # mint itself does not need that PDA, but SPENDING the token does:
    # Vault#enter_contest_with_token passes `user_pda` as a writable account. So
    # a gifted player would have held a token they could not play.
    def ensure_wallet!
      return @user.solana_address if @user.solana_address.present?

      @user.generate_managed_wallet!(reason: :gift)
      address = @user.reload.solana_address
      CreateOnchainUserAccountJob.perform_later(@user.id) if address.present?
      address
    end

    def unpayable_reason(address)
      return nil if address.present?

      @user.admin? ? ADMIN_REASON : NO_WALLET_REASON
    end

    def result(claimed, reason)
      Result.new(claimed: claimed, gift: @gift, reason: reason)
    end
  end
end
