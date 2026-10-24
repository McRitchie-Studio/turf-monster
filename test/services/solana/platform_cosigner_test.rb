require "test_helper"

# [unit] Solana::PlatformCosigner — the platform's second vault signature
# (Mr. McRitchie's 2026-10-24 ruling: "I'm only important if you need a third").
#
# Every key here derives from a published test seed and exists on no cluster.
class Solana::PlatformCosignerTest < ActiveSupport::TestCase
  SEED = "turf-monster platform cosigner test".freeze
  ALEX_7ZDJ = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze

  def key(role) = Solana::Keypair.from_bytes(Digest::SHA256.digest("#{SEED}:#{role}"))
  def secret(kp) = Solana::Keypair.encode_base58(kp.to_bytes)

  # A roster that knows nothing (so only the config-default Alex keys refuse),
  # or one that names `alex` as an operator key.
  class Roster
    def initialize(alex = []) = @alex = alex
    def operator?(address) = @alex.include?(address)
  end

  def load(kp, network: "mainnet-beta", expected: kp.address, roster: Roster.new, admin: key("admin").address)
    Solana::PlatformCosigner.load(env: { "SOLANA_PLATFORM_COSIGNER_KEY" => kp && secret(kp) },
                                  network: network, roster: roster, admin_address: admin, expected: expected)
  end

  # ── the boot check ────────────────────────────────────────────────────────

  test "a key that derives to the filed cosigner is configured" do
    platform = load(key("platform"))
    assert platform.configured?
    assert_equal key("platform").address, platform.address
    assert_match(/signs beside the server key/, platform.report)
  end

  test "an absent key is today's behaviour with a notice, never a raise" do
    platform = Solana::PlatformCosigner.load(env: {}, network: "mainnet-beta", roster: Roster.new, admin_address: nil)
    assert_equal :absent, platform.state
    refute platform.configured?
    assert_match(/SOLANA_PLATFORM_COSIGNER_KEY is not set/, platform.notice)
    assert_match(/every other signature comes from Mr. McRitchie's wallets/, platform.notice)
    assert_raises(Solana::PlatformCosigner::NotConfigured) { platform.sign_wire_base64("AA==") }
  end

  test "the boot check refuses a key the roster files as Alex's" do
    alex_like = key("alex-like")
    platform = load(alex_like, roster: Roster.new([alex_like.address]))
    assert_equal :refused, platform.state
    assert_match(/one of Mr. McRitchie's own wallets/, platform.reason)
    assert_match(/refused/, platform.report)
    assert_raises(Solana::PlatformCosigner::NotConfigured) { platform.keypair }
  end

  test "Alex's Phantom is refused even by a roster that forgot him" do
    reason = Solana::PlatformCosigner.refusal_for(ALEX_7ZDJ, network: "mainnet-beta", expected: ALEX_7ZDJ,
                                                             roster: Roster.new, admin_address: nil)
    assert_match(/one of Mr. McRitchie's own wallets/, reason)
  end

  test "the real roster refuses every one of Alex's wallets" do
    Solana::SignerRoster.default.alex_addresses.each do |address|
      reason = Solana::PlatformCosigner.refusal_for(address, network: "mainnet-beta", expected: address,
                                                             roster: Solana::SignerRoster.default, admin_address: nil)
      assert_match(/Mr. McRitchie's own wallets/, reason, address)
    end
  end

  test "the server's own key is refused: one key twice is not two signatures" do
    kp = key("platform")
    platform = load(kp, admin: kp.address)
    assert_equal :refused, platform.state
    assert_match(/server's own key/, platform.reason)
  end

  test "on mainnet a key that is not 3LTL is refused, naming 3LTL" do
    platform = load(key("platform"), expected: :filed)
    assert_equal :refused, platform.state
    assert_match(/mainnet-beta platform cosigner is 3LTLPG1s952sdNatZWtnfM7r9F3ivWSnPSqfhQLBepJ9/, platform.reason)
  end

  test "on devnet the filed cosigner is the devnet governance key" do
    platform = load(key("platform"), network: "devnet", expected: :filed)
    assert_equal :refused, platform.state
    assert_match(/devnet platform cosigner is BVQHNwUEo91ePwqPcR6Ro4g9Ejqt3qn3ajKPqJSSTd51/, platform.reason)
    assert_equal "BVQHNwUEo91ePwqPcR6Ro4g9Ejqt3qn3ajKPqJSSTd51", Solana::PlatformCosigner::EXPECTED_ADDRESSES["devnet"]
  end

  test "an unparseable key is refused without echoing it" do
    platform = Solana::PlatformCosigner.load(env: { "SOLANA_PLATFORM_COSIGNER_KEY" => "not-a-key!!" },
                                             network: "mainnet-beta", roster: Roster.new, admin_address: nil)
    assert_equal :refused, platform.state
    refute_includes platform.notice, "not-a-key!!"
  end

  # ── the signature application ─────────────────────────────────────────────

  # A settle-shaped wire: admin (fee payer) signed at build, the platform in
  # the named cosigner slot, and one extra slot for the operator's wallet.
  def partial_wire(admin, platform, operator)
    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.encode_base58(Digest::SHA256.digest("blockhash")))
    tx.add_signer(admin)
    tx.add_instruction(
      program_id: Solana::Keypair.decode_base58(Solana::Config::PROGRAM_ID),
      accounts: [
        { pubkey: admin.public_key_bytes, is_signer: true, is_writable: true },
        { pubkey: platform.public_key_bytes, is_signer: true, is_writable: false },
        { pubkey: operator.public_key_bytes, is_signer: true, is_writable: false }
      ],
      data: Solana::Transaction.anchor_discriminator("settle_contest")
    )
    tx.serialize_partial_base64(additional_signers: [platform.public_key_bytes, operator.public_key_bytes])
  end

  test "the platform fills its slot: two signatures present, the third slot empty" do
    admin, platform_kp, operator = key("admin"), key("platform"), key("operator")
    wire = load(platform_kp).sign_wire_base64(partial_wire(admin, platform_kp, operator))
    parsed = Solana::WireMessage.parse_base64(wire)

    assert_equal [admin, platform_kp, operator].map(&:public_key_bytes), parsed.signer_keys.map(&:b)
    assert parsed.signature_valid?(0), "the server's admin signature is present and valid"
    assert parsed.signature_valid?(1), "the platform cosigner's signature is present and valid"
    assert parsed.signature_slot_empty?(2), "the operator's slot is left for his wallet"

    # Exactly one more signature completes it.
    complete = Solana::Transaction.cosign_wire_base64(wire, signer: operator, require_complete: true)
    assert Solana::WireMessage.parse_base64(complete).signature_valid?(2)
  end

  test "the platform refuses a wire it holds no slot in" do
    admin, other, operator = key("admin"), key("other"), key("operator")
    assert_raises(RuntimeError) { load(key("platform")).sign_wire_base64(partial_wire(admin, other, operator)) }
  end
end
