require "test_helper"

# [unit] Vault#build_update_signers on the signer console's durable nonce:
# advanceNonceAccount is instruction 0, the nonce value is the blockhash, the
# server has signed before any wallet sees the wire, and nothing but a
# server-led build whose authority is the server key may take a nonce.
class Solana::VaultUpdateSignersNonceTest < ActiveSupport::TestCase
  NONCE = "9nL64UGmTj636sCMnds8yYXFD8HAMGK9bJnuXPoTyL7X".freeze

  def admin = Solana::Keypair.admin.to_base58

  def vault(value)
    data = [1, 1].pack("VV") + Solana::Keypair.admin.public_key_bytes +
           Solana::Keypair.decode_base58(value) + [5000].pack("Q<")
    info = { "value" => { "data" => [Base64.strict_encode64(data), "base64"] } }
    Solana::Vault.new(client: CosignFakeClient.build(get_account_info: ->(_pk, **) { info }))
  end

  def build(value, lead:, authority: admin)
    phantom = Solana::Keypair.generate.to_base58
    Solana::Config.stub(:governance?, false) do
      vault(value).build_update_signers(new_signers: [admin, phantom, Solana::Keypair.generate.to_base58],
                                        lead_signer: lead, cosigner_pubkey: phantom,
                                        durable_nonce: { pubkey: NONCE, authority: authority })
    end
  end

  test "a server-led build advances the nonce first and anchors on its value, server already signed" do
    value = Solana::Keypair.generate.to_base58
    result = build(value, lead: admin)
    wire = Solana::WireMessage.parse_base64(result[:serialized_tx])

    advance = wire.instructions.first
    assert_equal "\x00".b * 32, advance[:program_id], "instruction 0 is the System program"
    assert_equal 4, advance[:data].unpack1("V"), "and it is AdvanceNonceAccount"
    assert_equal [NONCE, admin], [advance[:accounts][0], advance[:accounts][2]].map { |k| Solana::Keypair.encode_base58(k) }
    assert_equal value, wire.recent_blockhash_base58
    assert wire.signature_valid?(0), "the server signed before Phantom sees it, so Phantom cannot rewrite it"
    assert_equal({ pubkey: NONCE, authority: admin, value: value }, result[:durable_nonce])
  end

  test "without a nonce the build carries no advance and reports none" do
    phantom = Solana::Keypair.generate.to_base58
    result = Solana::Config.stub(:governance?, false) do
      vault(Solana::Keypair.generate.to_base58)
        .build_update_signers(new_signers: [admin, phantom, Solana::Keypair.generate.to_base58],
                              lead_signer: admin, cosigner_pubkey: phantom)
    end
    wire = Solana::WireMessage.parse_base64(result[:serialized_tx])
    refute(wire.instructions.any? { |ix| ix[:program_id] == "\x00".b * 32 && ix[:data].unpack1("V") == 4 })
    assert_nil result[:durable_nonce]
  end

  test "an operator-led build refuses the nonce: Phantom would see it unsigned" do
    error = assert_raises(ArgumentError) { build(Solana::Keypair.generate.to_base58, lead: Solana::Keypair.generate.to_base58) }
    assert_match(/must be led by the server/, error.message)
  end

  test "a nonce whose authority is not the server key is refused" do
    error = assert_raises(ArgumentError) do
      build(Solana::Keypair.generate.to_base58, lead: admin, authority: Solana::Keypair.generate.to_base58)
    end
    assert_match(/authority must be the server key/, error.message)
  end
end
