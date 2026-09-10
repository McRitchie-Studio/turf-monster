require "test_helper"

class Solana::VaultEnsureProgramIdLiveTest < ActiveSupport::TestCase
  # Obviously fake. A real credential never appears in a test or its output.
  SENTINEL_KEY = "SENTINEL-NOT-A-REAL-KEY-0000".freeze

  setup { Rails.cache.clear }

  test "raises StaleEnvError when getAccountInfo returns null value" do
    fake_client = Object.new
    def fake_client.get_account_info(_)
      { "value" => nil }
    end

    err = assert_raises(Solana::Vault::StaleEnvError) do
      Solana::Vault.ensure_program_id_live!(client: fake_client)
    end
    assert_match(/PROGRAM_ID=/, err.message)
    assert_match(/does not exist on RPC/, err.message)
  end

  test "returns silently and caches when the program exists" do
    # Test env defaults Rails.cache to :null_store; swap in a real memory
    # store so we can verify the cache actually short-circuits the 2nd call.
    real_cache, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new

    fake_client = Object.new
    fake_client.instance_variable_set(:@calls, 0)
    def fake_client.calls = @calls
    def fake_client.get_account_info(_)
      @calls += 1
      { "value" => { "executable" => true, "owner" => "BPFLoaderUpgradeab1e11111111111111111111111" } }
    end

    assert_equal :live, Solana::Vault.ensure_program_id_live!(client: fake_client)
    assert_equal 1, fake_client.calls

    # Second call must NOT hit the RPC — cache should short-circuit.
    assert_equal :cached, Solana::Vault.ensure_program_id_live!(client: fake_client)
    assert_equal 1, fake_client.calls
  ensure
    Rails.cache = real_cache if real_cache
  end

  test "transient RPC errors are warned-and-swallowed, NOT raised" do
    fake_client = Object.new
    def fake_client.get_account_info(_)
      raise Solana::Client::RpcError.new("Too many requests for a specific RPC call")
    end

    # The fail-open contract TokenPurchaseJob depends on. Still not a raise.
    assert_nothing_raised { Solana::Vault.ensure_program_id_live!(client: fake_client) }
  end

  # ---------------------------------------------------------------------------
  # THE TRI-STATE (harden-solana-health-reporting)
  # ---------------------------------------------------------------------------
  # The guard fails OPEN on a transport error, deliberately. That made "it did
  # not raise" indistinguishable from "the program is there" — so `solana:health`
  # printed a green tick for a check that never executed, one line below
  # "getGenesisHash failed". The fix is NOT to raise (that would break the job's
  # contract, asserted directly above); it is to make the outcome REPORTABLE.

  test "an RPC error returns :unverified — a swallowed check is NOT a pass" do
    fake_client = Object.new
    def fake_client.get_account_info(_)
      raise JSON::ParserError, "unexpected token at 'Unauthorized'"
    end

    assert_equal :unverified, Solana::Vault.ensure_program_id_live!(client: fake_client),
                 "a check that did not run must never be reportable as a pass"
  end

  test "the swallowed-error WARNING does not publish the credential" do
    url = "https://rpc.example.test/?api-key=#{SENTINEL_KEY}"
    fake_client = Object.new
    fake_client.define_singleton_method(:get_account_info) do |_|
      # Shaped like the gem's real InsecureRpcUrlError message, which
      # interpolates the whole endpoint via `@rpc_url.inspect`.
      raise Solana::Client::InsecureRpcUrlError,
            "Solana::Client requires an https:// RPC URL (got #{url.inspect})."
    end

    logged = +""
    Rails.logger.stub(:warn, ->(line) { logged << line.to_s }) do
      assert_equal :unverified, Solana::Vault.ensure_program_id_live!(client: fake_client)
    end

    refute_includes logged, SENTINEL_KEY, "the RPC credential was written to the Rails log"
    assert_includes logged, "InsecureRpcUrlError", "the operator still needs the failure named"
  end

  test "force: true bypasses a cache entry so the CURRENT endpoint is actually probed" do
    # `solana:health` needs this: a ≤5-minute-old cache entry proves only that
    # some endpoint answered five minutes ago, which is worthless immediately
    # after a key rotation. The rake previously reached for
    # `Rails.cache.delete_matched(...) rescue nil`, whose bare rescue silently
    # ate the NotImplementedError unsupported stores raise — leaving the stale
    # entry, and the false tick, in place.
    real_cache, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new

    fake_client = Object.new
    fake_client.instance_variable_set(:@calls, 0)
    def fake_client.calls = @calls
    def fake_client.get_account_info(_)
      @calls += 1
      { "value" => { "executable" => true } }
    end

    assert_equal :live, Solana::Vault.ensure_program_id_live!(client: fake_client)
    assert_equal 1, fake_client.calls

    assert_equal :live, Solana::Vault.ensure_program_id_live!(client: fake_client, force: true)
    assert_equal 2, fake_client.calls, "force: true must re-probe, not answer from cache"
  ensure
    Rails.cache = real_cache if real_cache
  end
end
