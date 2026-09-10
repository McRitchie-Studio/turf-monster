module Solana
  # Prepended onto Solana::Client (from the solana-studio gem) to capture every
  # JSON-RPC call as an OutboundRequest row. Wrapped via prepend so we keep the
  # private visibility of the original `call` method.
  #
  # Activation: config/initializers/outbound_request_hooks.rb
  module ClientLogger
    # OPSEC-037: RPC methods whose first param is a base64 signed transaction.
    # A pre-broadcast partially-signed TX is replayable within the blockhash
    # window, and instruction data can carry payment references — never store
    # the raw payload in the outbound_requests audit table.
    REDACTED_TX_METHODS = %w[sendTransaction sendRawTransaction simulateTransaction].freeze

    # High-volume read-only RPCs called from every page render + wallet poll.
    # On a single dev machine these were generating ~75 outbound_requests rows
    # per minute — a row per call adds latency to every request that touches
    # Solana and grows the table without bound (the sweeper retains 90 days).
    # Successful reads are not audit-interesting; failures still log because
    # an RPC outage is operationally important. Writes — sendTransaction
    # etc. — always log: those are the security-relevant rows the audit
    # table exists for.
    UNAUDITED_READ_METHODS = %w[
      getAccountInfo
      getBalance
      getTokenAccountsByOwner
      getProgramAccounts
      getTokenAccountBalance
      getSignatureStatuses
      getLatestBlockhash
      getGenesisHash
    ].freeze

    private

    def call(method, params = [])
      started = Time.current
      result = nil
      error  = nil

      begin
        result = super
      rescue => e
        error = e
        raise
      ensure
        if log_outbound?(method, error)
          begin
            OutboundRequestLogger.record!(
              service:       "solana_rpc",
              method:        method.to_s,
              # REDACTED ON WRITE. log_outbound? returns true for every FAILED
              # call, and a key rotation drives a burst of failures — so the
              # moment of rotation was exactly when the OLD credential got
              # written into this table again. Revoking the key is not erasure
              # while these rows hold it verbatim. (Historical rows written
              # before this change still carry it; purging them is an ops task,
              # not a code one.)
              endpoint:      Solana::Config.redact_rpc_url((@rpc_url rescue nil)),
              request_body:  { method: method.to_s, params: redact_rpc_params(method, params) },
              response_body: error ? nil : { result: result },
              status_code:   error ? nil : 200,
              duration_ms:   ((Time.current - started) * 1000).round,
              error_class:   error&.class&.to_s,
              # Same exposure by a second route: InsecureRpcUrlError and
              # URI::InvalidURIError both carry the full endpoint in .message.
              error_message: error && Solana::Config.redact_message(error.message)
            )
          rescue => log_err
            Rails.logger.error "[outbound_request_logger] solana hook failed: #{log_err.message}"
          end
        end
      end
    end

    # Audit policy: always log on error (RPC outages are operational signal);
    # always log writes (sendTransaction etc.); skip high-volume successful
    # reads (getAccountInfo + friends) since they were drowning the table.
    def log_outbound?(method, error)
      return true if error
      !UNAUDITED_READ_METHODS.include?(method.to_s)
    end

    # OPSEC-037: replace a base64 signed-transaction payload with a hash +
    # byte length. Keeps any trailing config object (encoding, skipPreflight —
    # not sensitive); only the first param (the TX) is redacted.
    def redact_rpc_params(method, params)
      return params unless REDACTED_TX_METHODS.include?(method.to_s)
      return params unless params.is_a?(Array) && params[0].is_a?(String)

      tx = params[0]
      digest = Digest::SHA256.hexdigest(tx)
      ["[redacted tx — sha256:#{digest} (#{tx.bytesize} b64 bytes), OPSEC-037]"] + params[1..]
    end
  end
end
