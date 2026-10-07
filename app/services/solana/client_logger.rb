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
        stats = rpc_call_stats(error)
        if log_outbound?(method, error, stats)
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
              request_body:  { method: method.to_s, params: redact_rpc_params(method, params) }
                               .merge(rpc_wait_fields(stats)),
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
    # reads (getAccountInfo + friends) since they were drowning the table —
    # UNLESS the read needed retries. A read that succeeded only after waiting
    # out a 429 is the early sign of a throttled provider, and it is rare
    # enough not to drown anything.
    def log_outbound?(method, error, stats = nil)
      return true if error
      return true if stats && stats.retries.to_i.positive?
      !UNAUDITED_READ_METHODS.include?(method.to_s)
    end

    # What the gem's #call did (solana-studio >= 0.12.3): its retries, the
    # seconds it slept between them, and whether its wait budget stopped it.
    # A failed call carries its own on the error (RpcError#call_stats). A
    # successful one is read back from Client#last_call_stats, which is keyed
    # by thread AND client, so a client shared across request threads never
    # reads another thread's numbers. nil when neither is available (a
    # pre-0.12.3 client, a test double, or an error raised outside #call).
    def rpc_call_stats(error)
      if error
        error.respond_to?(:call_stats) ? error.call_stats : nil
      elsif respond_to?(:last_call_stats)
        last_call_stats
      end
    rescue StandardError
      nil # stats are observability; they never change what #call returns
    end

    # The stats as request_body fields. Empty when there are none, so a row
    # written without them reads exactly as it did before.
    def rpc_wait_fields(stats)
      return {} unless stats

      {
        retries:        stats.retries.to_i,
        waited_ms:      (stats.waited.to_f * 1000).round,
        budget_ms:      (stats.budget.to_f * 1000).round,
        budget_stopped: stats.budget_stopped ? true : false
      }
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
