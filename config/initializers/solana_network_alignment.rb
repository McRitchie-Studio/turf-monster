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
#
# ---------------------------------------------------------------------------
# WHAT IS FATAL HERE, AND WHAT IS NOT (survive-unauthorized-rpc-boot)
# ---------------------------------------------------------------------------
# Two outcomes, and they are not the same kind of fact:
#
#   DETERMINATE MISMATCH — the RPC answered, and the genesis hash it returned
#   belongs to a different cluster. That is EVIDENCE of a misconfiguration that
#   will silently move money onto the wrong chain. Still fatal. Unchanged.
#
#   INDETERMINATE — unreachable, unauthorized, rate-limited, or answering with
#   something that is not JSON. This proves NOTHING about alignment. Refusing to
#   boot on the absence of evidence converts a third-party outage into a
#   self-inflicted one, and this hook also runs during SLUG COMPILE — so a
#   provider blip would block the very deploy that fixes it. Log loudly, boot.
#
# That policy was always the intent: the old code rescued
# Solana::Client::RpcError and continued, saying so in as many words. The BUG
# was implementing it by NAMING ONE CLASS. solana-studio's Solana::Client#call
# runs `JSON.parse(response.body)` with no rescue, and wraps only
# Net::OpenTimeout / Net::ReadTimeout / Errno::ECONNRESET — so an unauthorized
# provider's plaintext "Unauthorized" arrived as a raw JSON::ParserError, a
# refused connection as Errno::ECONNREFUSED, a DNS failure as SocketError, and a
# bad URL as Solana::Client::InsecureRpcUrlError. Every one of them walked past
# the rescue and killed boot. Enumerating the classes a hostile upstream can
# produce is the mistake; there is no complete list, and the incomplete one
# turned a credential rotation into an outage with no rollback signal.
#
# So the probe rescues StandardError, and the fatal raise sits STRUCTURALLY
# OUTSIDE that rescue — it cannot be swallowed by the widening, now or later.
#
# The cost of the broad rescue is that a genuine bug in the probe (a
# NoMethodError, say) degrades to a log line instead of a crash — a security
# control that silently stops running. That is why this logs at ERROR with the
# exception CLASS named: "the check did not execute" is alertable, not a shrug.
# test/initializers/solana_network_alignment_test.rb drives this file with real
# non-JSON bodies off a real socket, and asserts BOTH halves — that the
# indeterminate cases boot, and that a real mismatch still refuses.
skip = Rails.env.test? || ENV["SOLANA_SKIP_NETWORK_CHECK"] == "true"

unless skip
  Rails.application.config.after_initialize do
    # Sourced from solana-studio's Solana::Network rather than a fourth private
    # copy of the table (the gem, this file, and lib/tasks/solana.rake each had
    # one). Looked up STRICTLY, not through Solana::Network.canonical: canonical
    # would resolve the alias "mainnet" to "mainnet-beta", while
    # Solana::Config.mainnet? compares exactly — so aliasing here would report
    # "aligned" for a value the rest of the app treats as not-mainnet. Same
    # semantics as the literal table this replaces.
    expected = Solana::Network::GENESIS_HASHES[Solana::Config::NETWORK]
    if expected.nil?
      Rails.logger.warn("[solana] unknown SOLANA_NETWORK=#{Solana::Config::NETWORK} — skipping alignment check")
    else
      failure = nil
      actual =
        begin
          Solana::Client.new(rpc_url: Solana::Config::RPC_URL).get_genesis_hash
        rescue StandardError => e
          # Upstream text is untrusted and can be an entire HTML page: scrub
          # invalid bytes, collapse whitespace so it cannot forge log lines, and
          # cap its length. scrub FIRST and never drop it: the JSON parser
          # quotes the offending token back in its message, so a body whose
          # first bytes are not UTF-8 (a latin-1 error page, a proxy's gzip
          # served without Content-Encoding) puts an invalid byte INSIDE
          # e.message — and gsub on that raises ArgumentError from inside this
          # rescue clause, where it is NOT caught. That aborts boot, which is
          # the exact bug this file exists to prevent.
          # redact_message, not a raw interpolation: two classes reachable here
          # embed the WHOLE credentialed endpoint in their message —
          # Solana::Client::InsecureRpcUrlError interpolates `@rpc_url.inspect`,
          # URI::InvalidURIError quotes the bad URI back — and `failure` is
          # printed below beside a second half that redacts correctly, which made
          # the line LOOK safe. It scrubs first for the reason described above,
          # then masks the credential.
          failure = "#{e.class}: #{Solana::Config.redact_message(e.message).truncate(200)}"
          nil
        end

      if actual.blank?
        # INDETERMINATE. redact_rpc_url is the shared redaction (see
        # Solana::Config) — this line fires precisely when the credential is the
        # problem, so it is exactly where a raw URL would leak one.
        Rails.logger.error(
          "[solana] alignment check INCONCLUSIVE for #{Solana::Config::NETWORK} — " \
          "#{failure || "the RPC returned no genesis hash"} " \
          "@ #{Solana::Config.redact_rpc_url(Solana::Config::RPC_URL)} — continuing boot. " \
          "The alignment guard did NOT run; transaction paths will surface the underlying error."
        )
      elsif actual != expected
        raise <<~MSG
          Solana network mis-alignment — refusing to boot (OPSEC-039).

            SOLANA_NETWORK    = #{Solana::Config::NETWORK}
            SOLANA_RPC_URL    = #{Solana::Config.redact_rpc_url(Solana::Config::RPC_URL)}
            SOLANA_PROGRAM_ID = #{Solana::Config::PROGRAM_ID}

            Expected genesis: #{expected}
            Actual genesis:   #{actual}
            Actual cluster:   #{Solana::Network.cluster_for_genesis(actual) || "unrecognized"}

          Fix the env var that's wrong (likely SOLANA_RPC_URL).
          To bypass during recovery: SOLANA_SKIP_NETWORK_CHECK=true.
        MSG
      else
        Rails.logger.info("[solana] network alignment OK (#{Solana::Config::NETWORK})")
      end
    end
  end
end
