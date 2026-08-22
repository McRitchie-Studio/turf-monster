require "test_helper"
require "rake"

# `solana:health` is the OPERATOR'S DIAGNOSTIC on the credential-rotation path —
# the thing you run after revoking an RPC key to find out what still works.
#
# It carried the same defect as the boot guard (survive-unauthorized-rpc-boot):
# its genesis-hash step rescued only Solana::Client::RpcError, so an unauthorized
# provider's non-JSON body came out of the gem as a raw JSON::ParserError and
# ABORTED THE WHOLE TASK at step 2 with a stack trace. Steps 3-5 — the IDL pin,
# the program ID, the rate-limit headers — never ran, which is precisely the
# information the operator ran it for.
#
# This is the integration tier for that fix: the real rake task, invoked
# end-to-end, against a real socket serving a real non-JSON body. It asserts the
# task REPORTS the failure and REACHES ITS VERDICT rather than exploding.
class SolanaHealthUnauthorizedRpcTest < ActiveSupport::TestCase
  # Obviously fake. A real credential never appears in a test, a log, or a
  # failure message — and this task prints its endpoint at the top, so the
  # redaction it uses is itself worth asserting.
  SENTINEL_KEY = "SENTINEL-NOT-A-REAL-KEY-0000".freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("solana:health")
    @task = Rake::Task["solana:health"]
    @task.reenable
  end

  test "reports an unauthorized RPC and still reaches its verdict" do
    output = nil

    NonJsonRpcEndpoint.serving(
      status: "401 Unauthorized", body: "Unauthorized", query: "api-key=#{SENTINEL_KEY}"
    ) do |endpoint|
      output = run_health_task(rpc_url: endpoint.url)
    end

    # Step 2 reports the real cause, by class, instead of raising it.
    assert_match(/getGenesisHash failed/, output)
    assert_match(/JSON::ParserError/, output,
                 "the operator needs the ACTUAL failure named — a non-JSON body from an " \
                 "unauthorized provider, not a generic 'RPC error'")

    # The whole point: execution continued past step 2 to the closing verdict.
    assert_match(/FAIL — fix the above before flipping traffic\./, output,
                 "the health check aborted before its verdict — steps 3-5 are exactly " \
                 "what the operator ran this for during a key rotation")

    # And the diagnostic must not publish the credential it is diagnosing.
    refute_includes output, SENTINEL_KEY,
                     "solana:health printed the RPC credential to the terminal"
    assert_match(/api-key=\*\*\*/, output,
                 "the operator still needs to see WHICH parameter was rejected")
  end

  # ---------------------------------------------------------------------------
  # THE FALSE GREEN (harden-solana-health-reporting)
  # ---------------------------------------------------------------------------
  test "does NOT tick PROGRAM_ID when the check could not run" do
    output = nil

    NonJsonRpcEndpoint.serving(
      status: "401 Unauthorized", body: "Unauthorized", query: "api-key=#{SENTINEL_KEY}"
    ) do |endpoint|
      output = run_health_task(rpc_url: endpoint.url)
    end

    # THE BUG, stated as an assertion: against an endpoint that rejects
    # everything, the task printed "✓ PROGRAM_ID exists on RPC" directly below
    # "getGenesisHash failed". Solana::Vault.ensure_program_id_live! fails OPEN
    # by design (TokenPurchaseJob depends on it), so the rake was reading "it
    # did not raise" as "it passed" for a check that never executed.
    refute_match(/✓ PROGRAM_ID exists on RPC/, output,
                 "solana:health printed a GREEN TICK for a check that never ran — the worst " \
                 "possible lie to tell an operator mid credential-rotation")
    assert_match(/✗ PROGRAM_ID check did NOT run \(unverified\)/, output,
                 "an unverified check must be reported as unverified, not silently omitted")

    # And it still reaches its verdict rather than raising.
    assert_match(/FAIL — fix the above before flipping traffic\./, output)
    refute_includes output, SENTINEL_KEY
  end

  # ---------------------------------------------------------------------------
  # THE MALFORMED ENDPOINT (harden-solana-health-reporting)
  # ---------------------------------------------------------------------------
  test "diagnoses a fat-fingered http:// endpoint instead of crashing" do
    # Solana::Client.new validates the scheme in its CONSTRUCTOR, and the rake
    # built the client OUTSIDE its begin — so the single most likely operator
    # error on the rotation path (a pasted http:// endpoint) killed the task
    # with a stack trace before any check could report it.
    output = run_health_task(rpc_url: "http://rpc.example.test/?api-key=#{SENTINEL_KEY}")

    assert_match(/RPC endpoint unusable/, output, "the task must NAME the bad endpoint as the problem")
    assert_match(/InsecureRpcUrlError/, output, "the operator needs the actual failure class")
    assert_match(/FAIL — fix the above before flipping traffic\./, output,
                 "the task crashed instead of reaching its verdict")

    # The message from that exception embeds the WHOLE credentialed URL
    # (`#{@rpc_url.inspect}` inside the gem). Printing it raw would publish the
    # very key the operator is rotating.
    refute_includes output, SENTINEL_KEY,
                     "solana:health printed the RPC credential while diagnosing a bad URL"
  end

  test "diagnoses an unparseable endpoint instead of crashing" do
    # URI::InvalidURIError quotes the offending URI back in its message — the
    # second credentialed-message class on this path.
    output = run_health_task(rpc_url: "https:// rpc.example.test/?api-key=#{SENTINEL_KEY}")

    assert_match(/RPC endpoint unusable/, output)
    assert_match(/FAIL — fix the above before flipping traffic\./, output)
    refute_includes output, SENTINEL_KEY,
                     "solana:health printed the RPC credential while diagnosing a bad URL"

    # Every downstream check must say it did not run, rather than tick.
    refute_match(/✓ RPC genesis/, output)
    refute_match(/✓ PROGRAM_ID exists on RPC/, output)
  end

  private

  # Invoke the real task with RPC_URL pointed at `rpc_url`. The task ends in
  # `exit <code>`, so SystemExit is the normal, expected finish.
  def run_health_task(rpc_url:)
    out = nil
    with_rpc_url(rpc_url) do
      out, = capture_io do
        assert_raises(SystemExit) { @task.invoke }
      end
    end
    out
  end

  # Swap the load-time constant rather than stubbing Solana::Client, so the
  # client, socket, HTTP exchange and JSON parse are all the real ones.
  def with_rpc_url(url)
    saved = Solana::Config::RPC_URL
    swap_rpc_url(url)
    yield
  ensure
    swap_rpc_url(saved)
  end

  def swap_rpc_url(url)
    Solana::Config.send(:remove_const, :RPC_URL)
    Solana::Config.const_set(:RPC_URL, url)
  end
end
