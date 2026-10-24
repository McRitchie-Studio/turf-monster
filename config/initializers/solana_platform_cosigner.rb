# Is SOLANA_PLATFORM_COSIGNER_KEY this cluster's filed platform cosigner (3LTL on
# mainnet, the devnet governance key on QA), and never one of Mr. McRitchie's
# wallets? Logged at boot on deployed apps beside the signer-isolation line;
# never raises. A refused or absent key leaves the app on two operator
# signatures per settle. The rule is Solana::PlatformCosigner.
unless Rails.env.test?
  Rails.application.config.after_initialize do
    next unless Rails.env.production?
    next if ENV["SECRET_KEY_BASE_DUMMY"].present?

    begin
      cosigner = Solana::PlatformCosigner.current
      level = { configured: :info, absent: :warn, refused: :error }.fetch(cosigner.state)
      Rails.logger.public_send(level, cosigner.report)
    rescue StandardError => e
      Rails.logger.error("[platform-cosigner] boot check did not run (#{e.class})")
    end
  end
end
