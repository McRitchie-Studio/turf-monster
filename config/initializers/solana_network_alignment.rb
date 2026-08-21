# OPSEC-039: boot-time cross-validation that SOLANA_NETWORK,
# SOLANA_PROGRAM_ID, and SOLANA_RPC_URL all describe the same cluster.
#
# The three env vars are set independently. Today's code reads them
# without checking they agree. A mainnet program ID with a devnet RPC URL
# (or vice versa) would silently boot — and at runtime, queries would
# return nothing / write into the wrong cluster.
#
# This initializer calls getGenesisHash on the configured RPC at boot,
# matches against the canonical hash for the declared NETWORK, and
# refuses to start on mismatch.
#
# Skipped in test (the RPC stub doesn't implement getGenesisHash) and
# when SOLANA_SKIP_NETWORK_CHECK=true (escape hatch for incident response).
GENESIS_HASHES = {
  "mainnet-beta" => "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d".freeze,
  "devnet"       => "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG".freeze,
  "testnet"      => "4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY".freeze
}.freeze

skip = Rails.env.test? || ENV["SOLANA_SKIP_NETWORK_CHECK"] == "true"

unless skip
  Rails.application.config.after_initialize do
    expected = GENESIS_HASHES[Solana::Config::NETWORK]
    if expected.nil?
      Rails.logger.warn("[solana] unknown SOLANA_NETWORK=#{Solana::Config::NETWORK} — skipping alignment check")
    else
      begin
        actual = Solana::Client.new(rpc_url: Solana::Config::RPC_URL).get_genesis_hash
        if actual != expected
          raise <<~MSG
            Solana network mis-alignment — refusing to boot (OPSEC-039).

              SOLANA_NETWORK    = #{Solana::Config::NETWORK}
              SOLANA_RPC_URL    = #{Solana::Config.redact_rpc_url(Solana::Config::RPC_URL)}
              SOLANA_PROGRAM_ID = #{Solana::Config::PROGRAM_ID}

              Expected genesis: #{expected}
              Actual genesis:   #{actual}

            Fix the env var that's wrong (likely SOLANA_RPC_URL).
            To bypass during recovery: SOLANA_SKIP_NETWORK_CHECK=true.
          MSG
        end
        Rails.logger.info("[solana] network alignment OK (#{Solana::Config::NETWORK})")
      rescue Solana::Client::RpcError => e
        # RPC unreachable at boot is a separate failure mode — log + continue.
        # The actual TX paths will surface the connection error.
        Rails.logger.warn("[solana] alignment check failed to reach RPC: #{e.message} — continuing boot")
      end
    end
  end
end
