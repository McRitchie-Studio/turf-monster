require "test_helper"

# bin/qa-signer-rotation's planner (task separate-qa-solana-signing-key).
#
# Two properties carry the weight. It must REFUSE every plan the program would
# reject or that would not actually isolate QA, and it must have NO path to a
# signature or a send: the read goes through ReadOnlyClient, and the inner
# client below records every call so the test sees exactly what reached it.
class Solana::QaSignerRotationTest < ActiveSupport::TestCase
  BOT   = "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd".freeze # production's system wallet
  ALEX  = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze
  MASON = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR".freeze
  QA_KEY = Solana::Keypair.from_bytes(Digest::SHA256.digest("qa-signer-rotation test qa")).to_base58
  OTHER = Solana::Keypair.from_bytes(Digest::SHA256.digest("qa-signer-rotation test other")).to_base58
  EMPTY = Solana::SignerRotation::EMPTY
  DEVNET_ID = Solana::QaSignerRotation::DEVNET_PROGRAM_ID

  # Answers get_account_info from a table and records every method called on
  # it, so a test can assert nothing but reads ever reached the network layer.
  class RecordingRpc
    attr_reader :calls

    def initialize(accounts)
      @accounts = accounts
      @calls = []
    end

    def get_account_info(pubkey, **)
      @calls << :get_account_info
      data = @accounts[pubkey]
      { "value" => data && { "data" => [Base64.strict_encode64(data), "base64"] } }
    end

    def method_missing(name, *)
      @calls << name
      raise "RecordingRpc: #{name} reached the network layer"
    end

    def respond_to_missing?(*) = true
  end

  def vault_state_bytes(slots)
    data = "\x00".b * (8 + 1507)
    slots.first(3).each_with_index { |k, i| data[8 + i * 32, 32] = Solana::Keypair.decode_base58(k) }
    slots[3, 2].to_a.each_with_index { |k, i| data[8 + 1443 + i * 32, 32] = Solana::Keypair.decode_base58(k) }
    data[8 + 96, 1] = [2].pack("C")
    data
  end

  def governance_bytes(update_signers: 3)
    thresholds = Array.new(32, 0)
    thresholds[Solana::Governance::ACTION_IDS.fetch("update_signers")] = update_signers
    "\x00".b * 8 + thresholds.pack("C*") + [86_400].pack("q<") + [250].pack("L<") + "\x00".b * 65
  end

  # A real Solana::Vault reading through the real ReadOnlyClient.
  def vault_for(slots, governance: false)
    probe = Solana::Vault.new(client: Object.new)
    accounts = { Solana::Keypair.encode_base58(probe.vault_state_pda.first) => vault_state_bytes(slots) }
    accounts[Solana::Keypair.encode_base58(probe.governance_pda.first)] = governance_bytes if governance
    @rpc = RecordingRpc.new(accounts)
    Solana::Vault.new(client: Solana::QaSignerRotation::ReadOnlyClient.new(@rpc))
  end

  def registry(production: BOT)
    Solana::SignerIsolation::Registry.new(
      "environments" => {
        "production" => { "network" => "mainnet-beta", "deployed" => true, "system_wallet" => production },
        "qa" => { "network" => "devnet", "deployed" => true, "system_wallet" => nil }
      }
    )
  end

  def plan(slots: [BOT, ALEX, MASON], governance: false, qa: QA_KEY, cosigners: [BOT, ALEX],
           replace: MASON, append: false, registry: self.registry, network: "devnet", program_id: DEVNET_ID)
    Solana::QaSignerRotation.new(qa_pubkey: qa, cosigners: cosigners, replace: replace, append: append,
                                 vault: vault_for(slots, governance: governance), registry: registry,
                                 network: network, program_id: program_id).plan
  end

  # ── PLANS THAT PASS ─────────────────────────────────────────────────────

  test "v0.25: the QA key takes Mason's slot, cosigned by the two keys that stay" do
    result = plan

    assert result.ok?, result.refusals.inspect
    assert_equal "v0.25", result.shape
    assert_equal [BOT, ALEX, QA_KEY], result.proposed, "every other key keeps its slot"
    assert_equal [MASON], result.evicted
    assert_equal 2, result.required
  end

  test "v0.25: evicting production's wallet from devnet passes and says what it breaks" do
    result = plan(replace: BOT, cosigners: [ALEX, MASON])

    assert result.ok?, result.refusals.inspect
    text = Solana::QaSignerRotation.render(result, qa_pubkey: QA_KEY, registry: registry)
    assert_match(/evicts #{BOT}, production's system wallet, from the DEVNET vault/, text)
    assert_match(/Mainnet is unaffected/, text)
  end

  test "v0.26: --append seats the QA key in the first empty slot with three signatures" do
    result = plan(governance: true, append: true, replace: nil, cosigners: [BOT, ALEX, MASON])

    assert result.ok?, result.refusals.inspect
    assert_equal "v0.26", result.shape
    assert_equal [BOT, ALEX, MASON, QA_KEY], result.proposed
    assert_empty result.evicted
  end

  # ── PLANS THE PROGRAM WOULD REJECT ──────────────────────────────────────

  test "continuity: a cosigner who is evicted by the rotation it signs is refused" do
    result = plan(replace: ALEX, cosigners: [BOT, ALEX])

    refute result.ok?
    assert_match(/SignerContinuityRequired, 6017/, result.refusals.join)
  end

  test "below threshold: one v0.25 signature is refused as Unauthorized (v0.25 has no 6046)" do
    result = plan(cosigners: [BOT])
    assert_match(/Unauthorized, 6000/, result.refusals.join)
    refute_match(/6046/, result.refusals.join)
  end

  # The regression (fix-qa-signer-ceremony-tooling). v0.25's update_signers has
  # two signer accounts, and the chain requires BOTH to stay. This plan named
  # three cosigners, two of which stay, and passed the dry run; on chain the
  # first two are admin and cosigner, 8K81 is evicted, and it fails 6017.
  test "v0.25: --replace 8K81 --cosigners 8K81,7ZDJ,CytJ is refused by the dry run" do
    result = plan(replace: BOT, cosigners: [BOT, ALEX, MASON])

    refute result.ok?, "the chain would reject this as SignerContinuityRequired"
    assert_match(/exactly 2 signers/, result.refusals.join)
  end

  test "v0.25: three cosigners are refused even when all three stay" do
    result = plan(governance: false, replace: MASON, cosigners: [BOT, ALEX, MASON])
    refute result.ok?
  end

  test "v0.25: two cosigners with the first one evicted is refused as continuity" do
    result = plan(replace: BOT, cosigners: [BOT, ALEX])
    assert_match(/SignerContinuityRequired, 6017/, result.refusals.join)
  end

  test "below threshold: two v0.26 signatures are refused where update_signers needs three" do
    result = plan(governance: true, append: true, replace: nil, cosigners: [BOT, ALEX])
    assert_match(/needs 3 vault signatures/, result.refusals.join)
  end

  # v0.25's validate_multisig wants s1 != s2, so a repeat is Unauthorized there;
  # DuplicateSigner 6014 is the NEW SET's rule, not the signers'.
  test "duplicate: the same cosigner twice is refused as Unauthorized on v0.25" do
    result = plan(cosigners: [BOT, BOT])
    assert_match(/Unauthorized, 6000/, result.refusals.join)
    assert_match(/more than once/, result.refusals.join)
  end

  test "duplicate: a QA key already in the set is refused" do
    result = plan(qa: ALEX, replace: MASON)
    assert_match(/already a devnet vault signer/, result.refusals.join)
  end

  test "a cosigner outside the set is refused" do
    result = plan(cosigners: [BOT, OTHER])
    assert_match(/Unauthorized, 6000/, result.refusals.join)
  end

  test "--append on the deployed v0.25 program is refused: it has no fourth slot" do
    result = plan(append: true, replace: nil)
    assert_match(/devnet runs v0.25/, result.refusals.join)
  end

  # ── WHAT THE OPERATOR IS TOLD ───────────────────────────────────────────

  test "the render names the program version whose rules it applied" do
    v025 = Solana::QaSignerRotation.render(plan, qa_pubkey: QA_KEY, registry: registry)
    assert_match(/rules applied: turf-vault v0\.25/, v025)

    refused = Solana::QaSignerRotation.render(plan(cosigners: [BOT, ALEX, MASON]), qa_pubkey: QA_KEY, registry: registry)
    assert_match(/rules applied: turf-vault v0\.25/, refused, "a refusal must say which rules refused it")

    v026 = plan(governance: true, append: true, replace: nil, cosigners: [BOT, ALEX, MASON])
    assert_match(/rules applied: turf-vault v0\.26/,
                 Solana::QaSignerRotation.render(v026, qa_pubkey: QA_KEY, registry: registry))
  end

  test "a passing plan prints the exact SOLANA_MULTISIG_SIGNERS value, in slot order" do
    text = Solana::QaSignerRotation.render(plan, qa_pubkey: QA_KEY, registry: registry)
    assert_includes text.lines.map(&:strip), "SOLANA_MULTISIG_SIGNERS=#{BOT},#{ALEX},#{QA_KEY}"

    b = Solana::QaSignerRotation.render(plan(replace: BOT, cosigners: [ALEX, MASON]), qa_pubkey: QA_KEY, registry: registry)
    assert_includes b.lines.map(&:strip), "SOLANA_MULTISIG_SIGNERS=#{QA_KEY},#{ALEX},#{MASON}"
  end

  test "a refused plan prints no SOLANA_MULTISIG_SIGNERS value to set" do
    text = Solana::QaSignerRotation.render(plan(cosigners: [BOT, ALEX, MASON]), qa_pubkey: QA_KEY, registry: registry)
    refute_match(/SOLANA_MULTISIG_SIGNERS=/, text)
  end

  # ── PLANS THAT WOULD NOT ISOLATE QA ─────────────────────────────────────

  test "a QA key equal to another environment's system wallet is refused" do
    result = plan(qa: OTHER, registry: registry(production: OTHER))
    assert_match(/is production's system wallet; QA must hold a key of its own/, result.refusals.join)
  end

  test "a QA key that is not a public key is refused" do
    assert_match(/not a 32-byte base58 public key/, plan(qa: "not-a-key").refusals.join)
  end

  # ── DEVNET ONLY ─────────────────────────────────────────────────────────

  test "mainnet is refused by network and by program id, before any read" do
    assert_raises(Solana::QaSignerRotation::WrongCluster) { plan(network: "mainnet-beta") }
    assert_empty @rpc.calls, "the refusal must come before the vault is read"
    assert_raises(Solana::QaSignerRotation::WrongCluster) do
      plan(program_id: Solana::QaSignerRotation::MAINNET_PROGRAM_ID)
    end
  end

  # ── NO SEND PATH ────────────────────────────────────────────────────────

  test "a full plan reaches the network only through get_account_info, and loads no key" do
    Solana::Keypair.stub(:admin, -> { raise "the dry run loaded a signing key" }) do
      result = plan
      assert result.ok?, result.refusals.inspect
      Solana::QaSignerRotation.render(result, qa_pubkey: QA_KEY, registry: registry)
    end

    assert_equal [:get_account_info], @rpc.calls.uniq
  end

  test "the read-only client refuses every write-shaped RPC before it reaches the network" do
    rpc = RecordingRpc.new({})
    client = Solana::QaSignerRotation::ReadOnlyClient.new(rpc)

    %i[send_transaction send_and_confirm simulate_transaction request_airdrop].each do |name|
      assert_raises(Solana::QaSignerRotation::ReadOnlyClient::WriteRefused) { client.public_send(name, "AAAA") }
      refute client.respond_to?(name)
    end
    assert_empty rpc.calls
  end

  test "the planner source names no signing or sending primitive" do
    source = Rails.root.join("app/services/solana/qa_signer_rotation.rb").read + Rails.root.join("bin/qa-signer-rotation").read
    code = source.lines.reject { |l| l.strip.start_with?("#") }.join
    %w[send_transaction send_and_confirm simulate_and_broadcast build_update_signers Keypair.admin .sign(].each do |primitive|
      refute_includes code, primitive, "the dry run must not reach #{primitive}"
    end
  end
end
