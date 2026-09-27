# Is this app's SOLANA_ADMIN_KEY its own environment's system wallet? Logged at
# boot on deployed apps; never raises. The rule is Solana::SignerIsolation
# (lib/solana/signer_isolation.rb), the filed public keys are
# config/solana_signers.yml, and the deploy-time gate is bin/deploy.
# See Solana::SignerIsolationBoot for why the boot half only reports.
unless Rails.env.test?
  Rails.application.config.after_initialize do
    Solana::SignerIsolationBoot.run
  end
end
