# frozen_string_literal: true

require "test_helper"

# The rehearsal refuses an agent co-signer key that is also a MAINNET
# VaultState signer, even on devnet (card devnet-v026-upgrade). The fence is
# filed, never read from mainnet; these tests read only the repo's config.
class QaRehearsalMainnetSignerFenceTest < ActiveSupport::TestCase
  Fence = TurfMonster::QaRehearsal::MainnetSignerFence
  Driver = TurfMonster::QaRehearsal::Driver

  XAN   = "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd"
  ALEX  = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr"
  MASON = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR"
  MACK  = "foUuRyeibadQoGdKXZ9pBGDqmkb1jY1jYsu8dZ29nds"
  QA    = "2eGs8G3wzhEeNQQU2Q86BmmA2xTpDbMMae3Y1bvpZfx9"

  # ── the filed list ────────────────────────────────────────────────────────

  test "the filed fence holds every seated mainnet signer and production's system wallet" do
    keys = Fence.load_keys
    [XAN, ALEX, MASON].each { |pk| assert_includes keys, pk }
    production = YAML.safe_load_file(Rails.root.join("config/solana_signers.yml"))
                     .dig("environments", "production", "system_wallet")
    assert_includes keys, production
  end

  test "the devnet-only keys are not fenced" do
    fence = Fence.default
    refute fence.fenced?(MACK), "Mack is the devnet rehearsal key"
    refute fence.fenced?(QA), "2eGs is QA's own devnet server key"
  end

  test "an empty or unreadable list refuses every key rather than clearing them" do
    Dir.mktmpdir do |dir|
      empty = File.join(dir, "fence.yml")
      File.write(empty, "seated: []\nincoming: []\n")
      none = File.join(dir, "none.yml")
      File.write(none, "environments: {}\n")
      assert_raises(Fence::Refused) { Fence.load_keys(fence_path: empty, isolation_path: none) }
      assert_raises(Fence::Refused) { Fence.load_keys(fence_path: File.join(dir, "missing.yml")) }
    end
  end

  test "refuse! names the fenced key and its holder" do
    error = assert_raises(Fence::Refused) do
      Fence.new(keys: [MASON]).refuse!([MACK, MASON], who: { MASON => "mason" })
    end
    assert_match(/mason \(#{MASON}\) is also a MAINNET VaultState signer/, error.message)
    assert_nil Fence.new(keys: [MASON]).refuse!([MACK])
  end

  # ── the driver ────────────────────────────────────────────────────────────

  class Keys
    attr_reader :loaded

    def initialize(map) = (@map = map) && (@loaded = [])

    def keypair(who)
      @loaded << who
      @map.fetch(who)
    end
  end

  def driver_with(agent_keys, fenced:)
    Driver.new(io: StringIO.new).tap do |d|
      d.instance_variable_set(:@keys, Keys.new(agent_keys))
      d.instance_variable_set(:@mainnet_fence, Fence.new(keys: fenced))
      d.define_singleton_method(:vault_agents) { agent_keys.keys }
    end
  end

  test "the driver refuses a filed agent key that is also a mainnet signer, before anything is signed" do
    devnet_only = Solana::Keypair.generate
    mainnet_too = Solana::Keypair.generate
    d = driver_with({ "mack" => devnet_only, "mason" => mainnet_too }, fenced: [mainnet_too.to_base58])
    request = { "action" => "settle_contest", "needed" => 1, "server" => QA,
                "seated" => [QA, devnet_only.to_base58, mainnet_too.to_base58] }

    error = assert_raises(Driver::StepError) { d.send(:pick_agents, request) }

    assert_match(/mason \(#{mainnet_too.to_base58}\) is also a MAINNET VaultState signer/, error.message)
    assert_match(/Nothing was signed or sent/, error.message)
  end

  test "a clean roster picks the seated devnet agent" do
    devnet_only = Solana::Keypair.generate
    d = driver_with({ "mack" => devnet_only }, fenced: [MASON, XAN])
    request = { "action" => "settle_contest", "needed" => 1, "server" => QA, "seated" => [QA, devnet_only.to_base58] }

    assert_equal [devnet_only.to_base58], d.send(:pick_agents, request).map(&:to_base58)
  end

  test "sign_and_send refuses a fenced signer however it was picked, and broadcasts nothing" do
    fenced = Solana::Keypair.generate
    d = driver_with({}, fenced: [fenced.to_base58])
    sent = []
    client = Object.new
    client.define_singleton_method(:send_and_confirm) { |w| sent << w }

    Solana::Config.stub(:client, client) do
      assert_raises(Driver::StepError) { d.send(:sign_and_send, { "serialized_tx" => "AAAA" }, [fenced]) }
    end
    assert_empty sent
  end

  test "the shipped roster files no fenced key" do
    fence = Fence.default
    # Public keys from the filed items' wallet-address fields, as KeyStore
    # cross-checks them; the roster must not name a mainnet signer's item.
    assert_equal %w[mack], Driver::VAULT_AGENTS
    refute fence.fenced?(MACK)
  end
end
