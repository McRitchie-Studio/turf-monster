require "test_helper"
require "stringio"

# The boot half of signer isolation: report, record once, never raise.
class Solana::SignerIsolationBootTest < ActiveSupport::TestCase
  PROD = Solana::Keypair.from_bytes(Digest::SHA256.digest("signer-isolation-boot prod"))
  QA = Solana::Keypair.from_bytes(Digest::SHA256.digest("signer-isolation-boot qa"))
  PROD_SECRET = Solana::Keypair.encode_base58(PROD.to_bytes)
  QA_SECRET = Solana::Keypair.encode_base58(QA.to_bytes)

  setup do
    @log = StringIO.new
    @logger = Logger.new(@log)
    @recorded = []
  end

  def registry(mode: "warn", qa_wallet: nil)
    Solana::SignerIsolation::Registry.new(
      "mode" => mode,
      "environments" => {
        "production" => { "network" => "mainnet-beta", "deployed" => true, "system_wallet" => PROD.to_base58 },
        "qa" => { "network" => "devnet", "deployed" => true, "system_wallet" => qa_wallet },
        "development" => { "network" => "devnet", "deployed" => false, "system_wallet" => nil }
      }
    )
  end

  def boot(env:, network: "devnet", deployed: true, registry: self.registry, recorder: nil)
    Solana::SignerIsolationBoot.run(env: env, network: network, deployed: deployed, logger: @logger,
                                    registry: registry, recorder: recorder || ->(e) { @recorded << e })
  end

  test "QA booting on production's key logs the finding and records it once from web.1" do
    verdict = boot(env: { "SOLANA_ADMIN_KEY" => PROD_SECRET, "DYNO" => "web.1" })

    assert_equal "qa", verdict.environment
    assert_equal %i[foreign unfiled], verdict.findings.map(&:kind)
    assert_match(/ERROR.*qa holds production's system wallet #{PROD.to_base58}/, @log.string)
    assert_equal 1, @recorded.length
    assert_kind_of Solana::SignerIsolationBoot::Finding, @recorded.first
    refute_includes @log.string, PROD_SECRET
    refute_includes @recorded.first.message, PROD_SECRET
  end

  test "other dynos log but do not record, so a restart is not a row per process" do
    boot(env: { "SOLANA_ADMIN_KEY" => PROD_SECRET, "DYNO" => "worker.1" })
    assert_match(/qa holds production's system wallet/, @log.string)
    assert_empty @recorded
  end

  test "enforce mode still never raises at boot" do
    verdict = boot(env: { "SOLANA_ADMIN_KEY" => PROD_SECRET, "DYNO" => "web.1" }, registry: registry(mode: "enforce"))
    assert verdict.refuse?, "the verdict says refuse; the boot must not act on it"
  end

  test "a failing recorder is logged, not raised" do
    verdict = boot(env: { "SOLANA_ADMIN_KEY" => PROD_SECRET, "DYNO" => "web.1" },
                   recorder: ->(_) { raise ActiveRecord::ConnectionNotEstablished, "no db" })
    refute_nil verdict
    assert_match(/could not record the finding \(ActiveRecord::ConnectionNotEstablished\)/, @log.string)
  end

  test "a matching key logs OK at info and records nothing" do
    verdict = boot(env: { "SOLANA_ADMIN_KEY" => QA_SECRET, "DYNO" => "web.1" }, registry: registry(qa_wallet: QA.to_base58))
    assert verdict.ok?
    assert_match(/INFO.*OK — this key IS qa's system wallet/, @log.string)
    assert_empty @recorded
  end

  test "production on mainnet with its own key is OK" do
    verdict = boot(env: { "SOLANA_ADMIN_KEY" => PROD_SECRET }, network: "mainnet-beta")
    assert_equal "production", verdict.environment
    assert verdict.ok?
  end

  test "not deployed, or precompiling assets, checks nothing" do
    assert_nil boot(env: { "SOLANA_ADMIN_KEY" => PROD_SECRET }, deployed: false)
    assert_nil boot(env: { "SOLANA_ADMIN_KEY" => PROD_SECRET, "SECRET_KEY_BASE_DUMMY" => "1" })
    assert_empty @log.string
  end

  test "an unfiled cluster is said out loud rather than skipped silently" do
    assert_nil boot(env: { "SOLANA_ADMIN_KEY" => PROD_SECRET }, network: "testnet")
    assert_match(/no environment .* is a deployed testnet app/, @log.string)
  end
end
