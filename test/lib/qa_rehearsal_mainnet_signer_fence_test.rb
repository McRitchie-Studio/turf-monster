# frozen_string_literal: true

require "test_helper"

# The rehearsal refuses an agent co-signer key that is also a MAINNET
# VaultState signer, even on devnet (card devnet-v026-upgrade). The fence is
# filed, never read from mainnet; these tests read only the repo's config.
class QaRehearsalMainnetSignerFenceTest < ActiveSupport::TestCase
  Fence = TurfMonster::QaRehearsal::MainnetSignerFence
  Driver = TurfMonster::QaRehearsal::Driver

  XAN   = "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd" # retired from mainnet 2026-10-14
  ALEX  = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr"
  MASON = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR" # retired from mainnet 2026-10-14
  SERVER = "4S39sKHHPV8GPjUif9noN9gdsAFGs9WASuGxs7B9s5CY"
  GOV_V2 = "3LTLPG1s952sdNatZWtnfM7r9F3ivWSnPSqfhQLBepJ9"
  # Mainnet VaultState, read 2026-10-14 11:10 MDT by turf-vault scripts/check-signer-slots.js.
  MAINNET_SLOTS = [GOV_V2, ALEX, SERVER, "9gACbzsCLmkYF9Yx1EBGmwMvvyfuTquJ6qs8QsoQvHXf",
                   "3Qj4v9qjhXgkru6zCRCErRVhy8Q6qU3NrNpvpXLTZboA"].freeze
  MACK  = "8UwJhRiNLr8uiqWyGUjgGDFqNEDY4SNQFfJud3ZSnowW" # devnet-only; foUu… retired 2026-10-24
  QA    = "2eGs8G3wzhEeNQQU2Q86BmmA2xTpDbMMae3Y1bvpZfx9"

  # ── the filed list ────────────────────────────────────────────────────────

  test "the filed fence holds every seated mainnet signer and production's system wallet" do
    keys = Fence.load_keys
    MAINNET_SLOTS.each { |pk| assert_includes keys, pk }
    production = YAML.safe_load_file(Rails.root.join("config/solana_signers.yml"))
                     .dig("environments", "production", "system_wallet")
    assert_includes keys, production
  end

  SYSTEM = "7auwTLSvNniSUeAgL6v9RStMXJhWrrUhSJgwFWLpcqC"

  test "every mainnet Squads member is fenced, including the Squad-only agent seat" do
    keys = Fence.load_keys
    squad = YAML.safe_load_file(Rails.root.join("config/mainnet_vault_signers.yml")).fetch("squad")
    assert_equal 5, squad.size, "the mainnet Squad is 3 of 5"
    squad.each { |pk| assert_includes keys, pk }
    assert_includes keys, SYSTEM, "solana.turf.system holds a mainnet Squad seat and no VaultState slot"
  end

  test "a Squad-only key is refused as a co-signer" do
    error = assert_raises(Fence::Refused) { Fence.default.refuse!([MACK, SYSTEM], who: { SYSTEM => "system" }) }
    assert_match(/system \(#{SYSTEM}\) also holds MAINNET authority/, error.message)
  end

  test "the Squad list is read: dropping it from the file unfences the Squad-only key" do
    Dir.mktmpdir do |dir|
      fence = File.join(dir, "fence.yml")
      filed = YAML.safe_load_file(Rails.root.join("config/mainnet_vault_signers.yml"))
      File.write(fence, filed.except("squad").to_yaml)
      refute_includes Fence.load_keys(fence_path: fence), SYSTEM
    end
  end

  test "the incoming list is read: a key filed only there is fenced" do
    planned = Solana::Keypair.generate.to_base58
    refute_includes Fence.load_keys, planned
    Dir.mktmpdir do |dir|
      fence = File.join(dir, "fence.yml")
      filed = YAML.safe_load_file(Rails.root.join("config/mainnet_vault_signers.yml"))
      File.write(fence, filed.merge("incoming" => [planned]).to_yaml)
      assert_includes Fence.load_keys(fence_path: fence), planned
    end
  end

  test "the keys the mainnet rotation retired stay fenced, and the retired list is read" do
    keys = Fence.load_keys
    assert_includes keys, XAN, "8K81 left the mainnet set but was not cleared to play"
    assert_includes keys, MASON, "Mason left the mainnet set but was not cleared to play"
    Dir.mktmpdir do |dir|
      fence = File.join(dir, "fence.yml")
      filed = YAML.safe_load_file(Rails.root.join("config/mainnet_vault_signers.yml"))
      File.write(fence, filed.except("retired").to_yaml)
      refute_includes Fence.load_keys(fence_path: fence), MASON
    end
  end

  test "seated is exactly the mainnet set read after the 2026-10-14 rotation, and nothing is incoming" do
    filed = YAML.safe_load_file(Rails.root.join("config/mainnet_vault_signers.yml"))
    assert_equal MAINNET_SLOTS.sort, filed.fetch("seated").sort
    assert_equal [], filed.fetch("incoming"), "the rotation seated its whole target; file the next one here when agreed"
  end

  # ── every key the driver loads ────────────────────────────────────────────

  test "FencedKeys refuses a fenced PLAYER key as it loads" do
    fenced = Solana::Keypair.generate
    store = Struct.new(:kp) { def keypair(_who) = kp }.new(fenced)
    keys = TurfMonster::QaRehearsal::MainnetSignerFence::FencedKeys.new(store, Fence.new(keys: [fenced.to_base58]))

    error = assert_raises(Fence::Refused) { keys.keypair("mason") }
    assert_match(/mason \(#{fenced.to_base58}\) also holds MAINNET authority/, error.message)
  end

  test "FencedKeys hands back an unfenced key" do
    clean = Solana::Keypair.generate
    store = Struct.new(:kp) { def keypair(_who) = kp }.new(clean)
    keys = TurfMonster::QaRehearsal::MainnetSignerFence::FencedKeys.new(store, Fence.new(keys: [MASON]))
    assert_equal clean.to_base58, keys.address("mack")
  end

  test "the driver's key store is fenced and Mason is out of the cast" do
    d = Driver.new(io: StringIO.new)
    d.define_singleton_method(:guard!) { true }
    assert_kind_of TurfMonster::QaRehearsal::MainnetSignerFence::FencedKeys, d.keys
    refute_includes Driver::DEFAULT_CAST, "mason"
    refute TurfMonster::QaRehearsal::KeyStore::ITEMS.key?("mason")
  end

  # Mr. McRitchie's PERSONAL Turf wallet, filed in the agent-readable item
  # solana.turf.alex (studio-agents). It signs for no program, but it holds his
  # own money, so the rehearsal must never load it (turf-devnet-config-truth).
  PERSONAL = "DKbvUsinni745s326a7xesEYCTcxSXv47xW79M1Z7E7r"

  test "Mr. McRitchie's personal wallet is filed under personal and fenced" do
    filed = YAML.safe_load_file(Rails.root.join("config/mainnet_vault_signers.yml"))
    assert_includes filed.fetch("personal"), PERSONAL
    refute_includes filed.fetch("seated"), PERSONAL, "DKbv holds no VaultState slot; it is fenced as personal"
    assert Fence.default.fenced?(PERSONAL)
  end

  test "the rehearsal refuses to load the personal wallet as a player" do
    store = Struct.new(:kp) { def keypair(_who) = kp }.new(Struct.new(:to_base58).new(PERSONAL))
    keys = Fence::FencedKeys.new(store, Fence.default)

    error = assert_raises(Fence::Refused) { keys.keypair("turf") }
    assert_match(/turf \(#{PERSONAL}\) also holds MAINNET authority or money/, error.message)
    assert_match(/personal wallets/, error.message)
  end

  test "the personal list is read: dropping it from the file unfences the wallet" do
    Dir.mktmpdir do |dir|
      fence = File.join(dir, "fence.yml")
      filed = YAML.safe_load_file(Rails.root.join("config/mainnet_vault_signers.yml"))
      File.write(fence, filed.except("personal").to_yaml)
      refute_includes Fence.load_keys(fence_path: fence), PERSONAL
    end
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
    assert_match(/mason \(#{MASON}\) also holds MAINNET authority/, error.message)
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

    assert_match(/mason \(#{mainnet_too.to_base58}\) also holds MAINNET authority/, error.message)
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
