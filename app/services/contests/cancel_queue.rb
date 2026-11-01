module Contests
  # Queue a contest's on-chain cancel for a cosign in the Treasury, for the
  # hub's operator endpoint (Operator::ContestOps#cancel). It builds exactly
  # what the admin button does (ContestsController#cancel_onchain): the same
  # refusals, the creator read off chain (the program constrains the refund
  # ATA's authority to contest.creator), Solana::Vault#build_cancel_contest,
  # and one `cancel_contest` PendingTransaction carrying `creator` in its
  # metadata (the Treasury's rebuild reads it).
  #
  # THE APP BUILDS IT AND NOBODY ELSE SIGNS IT HERE. build_cancel_contest
  # pre-signs the admin (payer) slot only, as the button always has; the cosign
  # is an owner's wallet in /admin/pending_transactions (AGENTS.md First Rule
  # 10). Nothing is broadcast, and no platform cosign is asked for: that stays
  # the Treasury checkbox (Solana::PlatformCosigner::ON_REQUEST_TX_TYPES).
  #
  # ONE AT A TIME. A cancel already waiting (pending or submitted) is returned,
  # not stacked, so a repeated call queues nothing new.
  #
  # It lives here, not in Contest or the controller, because
  # docs/workflows cites both by line number.
  class CancelQueue
    class Refused < StandardError; end

    IN_FLIGHT = %w[pending submitted].freeze

    def self.waiting(contest)
      PendingTransaction.where(target: contest, tx_type: "cancel_contest", status: IN_FLIGHT).order(:id).first
    end

    def initialize(contest, vault: Solana::Vault.new)
      @contest = contest
      @vault = vault
    end

    # [pending_transaction, created?]
    def call(metadata: {})
      raise Refused, "Contest is not on-chain" unless @contest.onchain?
      raise Refused, "Only open contests can be cancelled" unless @contest.open?
      raise Refused, "Contest is already cancelled" if @contest.onchain_cancelled?

      existing = self.class.waiting(@contest)
      return [ existing, false ] if existing

      onchain = @vault.read_contest(@contest.slug)
      raise Refused, "Could not read on-chain contest" unless onchain
      creator_pubkey = onchain[:creator]
      raise Refused, "On-chain creator unavailable" if creator_pubkey.blank?

      result = @vault.build_cancel_contest(@contest.slug, creator_pubkey: creator_pubkey,
                                                          cosigner_pubkey: Solana::Config::MULTISIG_COSIGNER)
      pending = PendingTransaction.create!(
        tx_type: "cancel_contest",
        serialized_tx: result[:serialized_tx],
        target: @contest,
        initiator_address: Solana::Keypair.admin.to_base58,
        metadata: metadata.to_h.stringify_keys.merge("creator" => creator_pubkey).to_json
      )
      [ pending, true ]
    end
  end
end
