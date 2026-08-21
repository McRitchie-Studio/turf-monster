require "test_helper"

# Unit half of redact-helius-key-from-browser. The integration suite
# (test/integration/rpc_credential_not_in_browser_test.rb) proves no browser
# surface emits a credential; this proves the PRIMITIVE those surfaces call.
#
# Nothing here contains a real key. Every fixture is a provider-SHAPED string
# with an obviously fake token, and the assertions are on the predicate rather
# than on any literal — the invariant has to hold for keys nobody typed here.
class Solana::PublicRpcUrlTest < ActiveSupport::TestCase
  FAKE = "FAKE0000000000000000000000000000".freeze

  # Every credential shape we can be handed. Named so a failure says WHICH.
  CREDENTIALED = {
    "helius api-key query"   => "https://mainnet.helius-rpc.com/?api-key=#{FAKE}",
    "generic token query"    => "https://rpc.example.com/?token=#{FAKE}",
    "bare key query"         => "https://rpc.example.com/?key=#{FAKE}",
    "http basic userinfo"    => "https://user:secret@rpc.example.com",
    "alchemy path key"       => "https://solana-mainnet.g.alchemy.com/v2/#{FAKE}",
    "quicknode path key"     => "https://sleek.solana-mainnet.quiknode.pro/#{FAKE}/",
    "unparseable"            => "https://rpc.example.com/ not a url"
  }.freeze

  CLEAN = {
    "public devnet"  => "https://api.devnet.solana.com",
    "public mainnet" => "https://api.mainnet-beta.solana.com",
    "public testnet" => "https://api.testnet.solana.com",
    "localnet"       => "http://127.0.0.1:8899",
    "bare host"      => "https://rpc.example.com"
  }.freeze

  def with_public_rpc_env(value)
    previous = ENV["SOLANA_PUBLIC_RPC_URL"]
    if value.nil?
      ENV.delete("SOLANA_PUBLIC_RPC_URL")
    else
      ENV["SOLANA_PUBLIC_RPC_URL"] = value
    end
    yield
  ensure
    previous.nil? ? ENV.delete("SOLANA_PUBLIC_RPC_URL") : ENV["SOLANA_PUBLIC_RPC_URL"] = previous
  end

  # --- the predicate ---

  test "credentialed_rpc_url? flags every credential shape" do
    CREDENTIALED.each do |shape, url|
      assert Solana::Config.credentialed_rpc_url?(url),
             "#{shape} must be treated as credential-bearing"
    end
  end

  test "credentialed_rpc_url? passes credential-free endpoints" do
    CLEAN.each do |shape, url|
      refute Solana::Config.credentialed_rpc_url?(url),
             "#{shape} carries no credential and must not be downgraded"
    end
  end

  test "credentialed_rpc_url? treats blank as not-credentialed" do
    refute Solana::Config.credentialed_rpc_url?(nil)
    refute Solana::Config.credentialed_rpc_url?("")
  end

  # --- resolution ---

  test "a credentialed RPC_URL is never handed to the browser" do
    CREDENTIALED.each do |shape, url|
      %w[mainnet-beta devnet testnet localnet].each do |network|
        with_public_rpc_env(nil) do
          resolved = Solana::Config.public_rpc_url(url, network)
          refute Solana::Config.credentialed_rpc_url?(resolved),
                 "#{shape} on #{network} resolved to a credentialed browser URL"
          assert resolved.present?, "#{shape} on #{network} resolved to nothing"
        end
      end
    end
  end

  test "a keyed mainnet RPC_URL falls back to the canonical public mainnet endpoint" do
    with_public_rpc_env(nil) do
      assert_equal "https://api.mainnet-beta.solana.com",
                   Solana::Config.public_rpc_url(CREDENTIALED["helius api-key query"], "mainnet-beta")
    end
  end

  test "an unknown cluster falls back to devnet rather than to the keyed URL" do
    with_public_rpc_env(nil) do
      assert_equal Solana::Config::DEFAULT_PUBLIC_RPC_URL,
                   Solana::Config.public_rpc_url(CREDENTIALED["helius api-key query"], "localnet")
    end
  end

  # Dev / test / QA parity: their SOLANA_RPC_URL is the public devnet endpoint,
  # so the browser must receive it BYTE-IDENTICALLY. If this ever fails, the
  # fix silently repointed every local and QA client RPC call.
  test "a credential-free RPC_URL reaches the browser unchanged" do
    with_public_rpc_env(nil) do
      CLEAN.each do |shape, url|
        assert_equal url, Solana::Config.public_rpc_url(url, "devnet"),
                     "#{shape} must pass through untouched"
      end
    end
  end

  test "SOLANA_PUBLIC_RPC_URL wins when it carries no credential" do
    with_public_rpc_env("https://browser.rpc.example.com") do
      assert_equal "https://browser.rpc.example.com",
                   Solana::Config.public_rpc_url(CREDENTIALED["helius api-key query"], "mainnet-beta")
    end
  end

  # The guard has to bite on the EMISSION, not on the operator having
  # remembered which variable is the safe one. A credential pasted into the
  # browser-facing variable is dropped, not served.
  test "a credentialed SOLANA_PUBLIC_RPC_URL is DROPPED, not served" do
    CREDENTIALED.each do |shape, url|
      with_public_rpc_env(url) do
        resolved = Solana::Config.public_rpc_url("https://api.mainnet-beta.solana.com", "mainnet-beta")
        refute Solana::Config.credentialed_rpc_url?(resolved),
               "#{shape} in SOLANA_PUBLIC_RPC_URL was served to the browser"
        assert_equal "https://api.mainnet-beta.solana.com", resolved
      end
    end
  end

  test "a blank SOLANA_PUBLIC_RPC_URL is ignored rather than emitted" do
    with_public_rpc_env("   ") do
      assert_equal "https://api.devnet.solana.com",
                   Solana::Config.public_rpc_url("https://api.devnet.solana.com", "devnet")
    end
  end

  # --- redaction (shared by the solana:health / solana:preflight rakes) ---

  test "redact_rpc_url removes every credential shape" do
    CREDENTIALED.each do |shape, url|
      redacted = Solana::Config.redact_rpc_url(url)
      refute_includes redacted, FAKE, "#{shape}: the token survived redaction"
      refute_includes redacted, "secret", "#{shape}: the password survived redaction"
    end
  end

  test "redact_rpc_url leaves a credential-free endpoint legible" do
    assert_equal "https://api.devnet.solana.com",
                 Solana::Config.redact_rpc_url("https://api.devnet.solana.com")
    assert_equal "", Solana::Config.redact_rpc_url(nil)
  end

  # The param NAME is what tells an operator which variable to go fix, so it
  # must survive even though its value does not.
  test "redact_rpc_url keeps the query key and drops only the value" do
    redacted = Solana::Config.redact_rpc_url(CREDENTIALED["helius api-key query"])
    assert_includes redacted, "api-key=***"
    assert_includes redacted, "mainnet.helius-rpc.com"
  end
end
