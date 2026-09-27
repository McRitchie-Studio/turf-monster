module Solana
  # The boot-time half of Solana::SignerIsolation: a deployed app states, in
  # its own log, whether the key it loaded is its own environment's system
  # wallet (task separate-qa-solana-signing-key).
  #
  # IT NEVER RAISES AND NEVER REFUSES, in either mode. `enforce` is a DEPLOY
  # gate (bin/deploy). A boot that refused would take QA down over a finding
  # that only the signer ceremony can clear, which is the freeze
  # turf-monster#624 was closed for, moved from the deploy to the dyno.
  #
  # What it does on a finding: one ERROR log line naming public keys only, and
  # one ErrorLog row from the first web dyno so the finding shows up in
  # /error_logs instead of only in a log drain. Every other dyno logs and
  # records nothing, so a restart does not write a row per process.
  #
  # Where it runs: deployed apps only (Rails production), and not during asset
  # precompile, which boots with a dummy secret and no reason to judge a key.
  class SignerIsolationBoot
    # Raised only to hand ErrorLog.capture! an exception; its message is the
    # guard's report, which carries public keys and words, never a secret.
    class Finding < StandardError; end

    RECORDING_DYNO = "web.1".freeze

    def self.run(env: ENV, network: Config::NETWORK, deployed: Rails.env.production?,
                 logger: Rails.logger, registry: nil, recorder: nil)
      new(env: env, network: network, deployed: deployed, logger: logger,
          registry: registry, recorder: recorder).run
    end

    def initialize(env:, network:, deployed:, logger:, registry:, recorder:)
      @env = env
      @network = network
      @deployed = deployed
      @logger = logger
      @registry = registry
      @recorder = recorder || ->(error) { ErrorLog.capture!(error) }
    end

    # Returns the verdict, or nil when the check does not apply here.
    def run
      return nil unless @deployed
      return nil if @env["SECRET_KEY_BASE_DUMMY"].present?

      registry = @registry || SignerIsolation::Registry.load
      environment = registry.environment_for(network: @network, deployed: true)
      if environment.nil?
        @logger.error("[signer-isolation] no environment in config/solana_signers.yml is a deployed #{@network} app; " \
                      "this app's key was not checked")
        return nil
      end

      verdict = SignerIsolation.check(env: @env, environment: environment, registry: registry)
      if verdict.ok?
        @logger.info("[signer-isolation] #{verdict.report}")
      else
        @logger.error("[signer-isolation] #{verdict.report.gsub("\n", ' | ')}")
        record(verdict)
      end
      verdict
    rescue StandardError => e
      # The class only: a message from deep in a key read is not something to
      # put in a log line unexamined.
      @logger.error("[signer-isolation] boot check did not run (#{e.class})")
      nil
    end

    private

    def record(verdict)
      return unless @env["DYNO"] == RECORDING_DYNO

      @recorder.call(Finding.new(verdict.report))
    rescue StandardError => e
      @logger.error("[signer-isolation] could not record the finding (#{e.class})")
    end
  end
end
