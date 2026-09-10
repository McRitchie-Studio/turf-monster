require "test_helper"

class Solana::ClientLoggerTest < ActiveSupport::TestCase
  # Build a minimal harness that mimics the gem's Client + the prepend chain
  # without hitting the real JSON-RPC endpoint.
  class FakeClient
    attr_accessor :rpc_url
    def initialize; @rpc_url = "https://fake.devnet.test"; end
    private
    def call(method, params = []); { "result" => "ok-for-#{method}", "echo" => params }; end
  end

  class FailingClient
    attr_accessor :rpc_url
    def initialize; @rpc_url = "https://fake.devnet.test"; end
    private
    def call(_method, _params = []); raise StandardError, "rpc boom"; end
  end

  setup do
    FakeClient.prepend(Solana::ClientLogger) unless FakeClient.ancestors.include?(Solana::ClientLogger)
    FailingClient.prepend(Solana::ClientLogger) unless FailingClient.ancestors.include?(Solana::ClientLogger)
  end

  test "logs a successful write call" do
    client = FakeClient.new
    assert_difference -> { OutboundRequest.count }, 1 do
      result = client.send(:call, "sendTransaction", ["BASE64SIGNED", { "encoding" => "base64" }])
      assert_equal "ok-for-sendTransaction", result["result"]
    end
    rec = OutboundRequest.last
    assert_equal "solana_rpc", rec.service
    assert_equal "sendTransaction", rec.method
    assert_equal 200, rec.status_code
    assert rec.duration_ms >= 0
    assert_nil rec.error_class
  end

  test "skips successful high-volume read methods to keep the audit table sane" do
    # Smell #1 from the 24h log review: getAccountInfo + getBalance + token
    # account scans were generating ~75 outbound_requests rows/min from one
    # dev machine. Successful reads are not audit-interesting; failures and
    # writes still log (see the next two tests).
    client = FakeClient.new
    %w[getAccountInfo getBalance getTokenAccountsByOwner getProgramAccounts].each do |m|
      assert_no_difference -> { OutboundRequest.count }, "expected no row for read method #{m}" do
        client.send(:call, m, [])
      end
    end
  end

  test "logs read methods when they ERROR (operational signal)" do
    # An RPC outage on read methods is operationally important — we want
    # those rows even though the happy-path reads are filtered.
    client = FailingClient.new
    assert_difference -> { OutboundRequest.count }, 1 do
      assert_raises(StandardError) { client.send(:call, "getAccountInfo") }
    end
    rec = OutboundRequest.last
    assert_equal "getAccountInfo", rec.method
    assert_equal "StandardError", rec.error_class
  end

  test "logs and re-raises a failing call" do
    client = FailingClient.new
    assert_difference -> { OutboundRequest.count }, 1 do
      assert_raises(StandardError) { client.send(:call, "boom") }
    end
    rec = OutboundRequest.last
    assert_equal "solana_rpc", rec.service
    assert_equal "boom", rec.method
    assert_nil rec.status_code
    assert_equal "StandardError", rec.error_class
    assert_match(/rpc boom/, rec.error_message)
  end

  test "redacts the signed-transaction param for sendTransaction (OPSEC-037)" do
    client = FakeClient.new
    raw_tx = "BASE64SIGNEDTX" + ("x" * 400)
    client.send(:call, "sendTransaction", [raw_tx, { "encoding" => "base64" }])
    params = OutboundRequest.last.request_body["params"]
    refute_includes params.to_s, raw_tx, "raw signed TX bytes must not be stored"
    assert_match(/redacted tx/, params.first.to_s)
    assert_match(/sha256:/, params.first.to_s)
  end
  # ---------------------------------------------------------------------------
  # THE CREDENTIAL IN THE AUDIT TABLE (harden-solana-health-reporting)
  # ---------------------------------------------------------------------------
  # log_outbound? returns true for EVERY failed call, and a key rotation drives
  # a burst of failures — so the moment of rotation was precisely when the OLD
  # credential got written into outbound_requests again. Revoking a key is not
  # erasure while these rows hold it verbatim.
  SENTINEL_KEY = "SENTINEL-NOT-A-REAL-KEY-0000".freeze

  class CredentialedFailingClient
    attr_accessor :rpc_url
    def initialize(url); @rpc_url = url; end
    private
    def call(_method, _params = [])
      raise Solana::Client::InsecureRpcUrlError,
            "Solana::Client requires an https:// RPC URL (got #{@rpc_url.inspect})."
    end
  end

  test "the logged endpoint is redacted, not the raw credentialed URL" do
    url = "https://rpc.example.test/?api-key=#{SENTINEL_KEY}"
    CredentialedFailingClient.prepend(Solana::ClientLogger)
    client = CredentialedFailingClient.new(url)

    assert_difference -> { OutboundRequest.count }, 1 do
      assert_raises(Solana::Client::InsecureRpcUrlError) { client.send(:call, "getAccountInfo") }
    end

    rec = OutboundRequest.last
    refute_includes rec.endpoint.to_s, SENTINEL_KEY,
                    "the RPC credential was persisted into outbound_requests.endpoint"
    assert_includes rec.endpoint.to_s, "api-key=***",
                    "the operator still needs to know WHICH endpoint shape failed"
  end

  test "the logged error_message is redacted — the second route to the same row" do
    url = "https://rpc.example.test/?api-key=#{SENTINEL_KEY}"
    CredentialedFailingClient.prepend(Solana::ClientLogger)
    client = CredentialedFailingClient.new(url)

    assert_raises(Solana::Client::InsecureRpcUrlError) { client.send(:call, "getAccountInfo") }

    rec = OutboundRequest.last
    refute_includes rec.error_message.to_s, SENTINEL_KEY,
                    "the exception message carried the credential into outbound_requests"
    assert_includes rec.error_message.to_s, "requires an https:// RPC URL",
                    "the diagnostic itself must survive redaction"
  end
end
