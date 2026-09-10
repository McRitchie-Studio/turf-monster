require "test_helper"
require "rake"

# `solana:preflight` is `solana:health`'s sibling on the credential-rotation
# path, and it carried the same leak: its VaultState step rescues StandardError
# and prints `e.message[0, 160]`.
#
# Truncating is not redacting. `Solana::Vault.new` builds a Solana::Client, whose
# CONSTRUCTOR raises Solana::Client::InsecureRpcUrlError for a non-https endpoint
# — and the gem interpolates `@rpc_url.inspect` into that message, so the whole
# credentialed URL sits at the FRONT of the string, well inside the first 160
# characters. A fat-fingered endpoint is the most likely operator error during a
# key rotation, which is exactly when this task gets run.
class SolanaPreflightRedactionTest < ActiveSupport::TestCase
  # Obviously fake. A real credential never appears in a test or its output.
  SENTINEL_KEY = "SENTINEL-NOT-A-REAL-KEY-0000".freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("solana:preflight")
    @task = Rake::Task["solana:preflight"]
    @task.reenable
  end

  test "a bad endpoint's exception message does not publish the credential" do
    url = "http://rpc.example.test/?api-key=#{SENTINEL_KEY}"
    # The exception is INJECTED rather than provoked by the swapped URL: the
    # test suite stubs the RPC transport, so Solana::Vault.new here never runs
    # the real constructor validation that raises in production. What is under
    # test is this rake's RESCUE — whether it formats an exception through the
    # redaction or straight into the terminal — and injecting the exception is
    # the only way to reach that branch. The redaction itself is exercised
    # against real inputs in test/services/solana/config_redact_message_test.rb.
    raiser = lambda do
      raise Solana::Client::InsecureRpcUrlError,
            "Solana::Client requires an https:// RPC URL (got #{url.inspect}). " \
            "Plain http:// is only allowed for localhost."
    end

    output = Solana::Vault.stub(:new, raiser) { run_preflight(rpc_url: url) }

    refute_includes output, SENTINEL_KEY,
                     "solana:preflight printed the RPC credential while diagnosing a bad URL"
    assert_match(/VaultState read failed/, output,
                 "the operator still needs to be told the vault read failed")
    assert_match(/FAIL — fix the above/, output, "the task must still reach its verdict")
  end

  private

  # The task ends in `exit <code>`, so SystemExit is the normal finish.
  def run_preflight(rpc_url:)
    out = nil
    with_rpc_url(rpc_url) do
      out, = capture_io do
        assert_raises(SystemExit) { @task.invoke }
      end
    end
    out
  end

  # Swap the load-time constant rather than stubbing Solana::Client, so the
  # client's real constructor validation is what raises.
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
