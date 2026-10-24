module Solana
  # Builds that take the platform's second signature (Solana::PlatformCosigner,
  # Mr. McRitchie's 2026-10-24 ruling). The rule for WHEN lives on
  # Solana::CosignPlan; this module only assembles and signs.
  module PlatformCosign
    module_function

    # The settle a graded contest queues (Contest#settle_onchain!).
    #
    # With the platform cosigner: the server signs as admin, the platform
    # cosigner signs the named `cosigner` slot, and the extra slots are
    # reserved for Mr. McRitchie's highest-priority seated wallets, so the
    # queued row already holds two signatures and needs exactly one more. The
    # operator can still pick a different wallet of his: the Co-sign click
    # rebuilds on a fresh blockhash against his choice.
    #
    # Without it (absent, refused, not seated, a durable-nonce cluster, or too
    # few of his wallets seated to reserve), the build is the one that shipped
    # before: SettleNonce.build_settle with the default cosigner.
    def build_settle(vault:, slug:, settlements:, platform: PlatformCosigner.current,
                     plan: CosignPlan.new(tx_type: "settle_contest"), nonce: SettleNonce.current)
      if nonce.nil? && plan.platform_cosign?(platform: platform)
        needed = plan.extra_cosigners_needed
        extras = CosignPlan.default_extras(CosignPlan.eligible_cosigners - [platform.address], needed)
        if extras.length == needed
          result = vault.build_settle_contest(slug, settlements, cosigner_pubkey: platform.address,
                                                                 extra_cosigners: extras)
          return result.merge(serialized_tx: platform.sign_wire_base64(result[:serialized_tx]),
                              cosigner: platform.address, platform_cosigner: platform.address,
                              extra_cosigners: extras)
        end
      end

      SettleNonce.build_settle(vault: vault, slug: slug, settlements: settlements,
                               default_cosigner: Config::MULTISIG_COSIGNER, settings: nonce)
    end
  end
end
