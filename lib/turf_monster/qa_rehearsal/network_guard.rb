# frozen_string_literal: true

module TurfMonster
  module QaRehearsal
    # Refuses to run the rehearsal anywhere but devnet.
    #
    # This is the most important object in the driver, and it earns that by
    # what it stands in front of: the rehearsal loads Mason's keypair, and
    # Mason is a signer on the MAINNET vault multisig too — the same key on
    # both networks. A driver pointed at the wrong app could co-sign a real
    # treasury transaction. So the guard runs BEFORE KeyStore is ever touched,
    # and it fails closed on anything it cannot prove.
    #
    # It asks the deployed app's own config rather than trusting a flag on the
    # command line, mirroring the precondition in Turf Monster's
    # `live-score-watch` SOP: `RAILS_ENV` cannot answer this question, because
    # every Heroku app runs production and QA prints `production` identically.
    # SOLANA_NETWORK is the half that discriminates.
    #
    # Both facts are checked. The network alone would pass on any future devnet
    # app; the program id alone would pass if someone pointed a mainnet app at
    # the devnet program. Together they name one deployment.
    class NetworkGuard
      class RefusedError < StandardError; end

      EXPECTED_NETWORK = "devnet"
      EXPECTED_PROGRAM = "EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ"

      # Apps this driver is ever allowed to touch. A belt to the braces above:
      # even a devnet-configured app has to be one we named.
      ALLOWED_APPS = ["turf-monster-qa"].freeze

      attr_reader :app

      # @param app [String] Heroku app name
      # @param reader [#call] receives (app, var) and returns the config value.
      #   Injectable so the refusal paths are testable without a network call.
      def initialize(app:, reader: nil)
        @app = app.to_s
        @reader = reader || method(:heroku_config_get)
      end

      # @return [Hash] the proven facts, for the caller to print
      # @raise [RefusedError] when the target is not provably the devnet QA app
      def assert!
        unless ALLOWED_APPS.include?(app)
          refuse("app #{app.inspect} is not in the allow-list #{ALLOWED_APPS.inspect}")
        end

        network = read("SOLANA_NETWORK")
        program = read("SOLANA_PROGRAM_ID")

        unless network == EXPECTED_NETWORK
          refuse("#{app} reports SOLANA_NETWORK=#{network.inspect}, expected #{EXPECTED_NETWORK.inspect}")
        end

        unless program == EXPECTED_PROGRAM
          refuse("#{app} reports SOLANA_PROGRAM_ID=#{program.inspect}, expected #{EXPECTED_PROGRAM.inspect}")
        end

        { app: app, network: network, program_id: program }
      end

      private

      def read(var)
        value = @reader.call(app, var).to_s.strip
        refuse("could not read #{var} from #{app}") if value.empty?
        value
      end

      # Phrased as a refusal, not a failure: the driver declined to act on an
      # answer it does not trust. The distinction matters in a transcript.
      def refuse(reason)
        raise RefusedError, "REFUSED — this driver only runs against devnet QA: #{reason}"
      end

      def heroku_config_get(app, var)
        require "open3"
        out, _err, status = Open3.capture3("heroku", "config:get", var, "-a", app)
        status.success? ? out : ""
      end
    end
  end
end
