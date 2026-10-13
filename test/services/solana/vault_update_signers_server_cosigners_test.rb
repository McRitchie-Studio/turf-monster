require "test_helper"

# [unit] Vault#build_update_signers signs every SERVER-HELD cosigner at build
# time (SOLANA_COSIGNER_KEYS), leaves only Phantom's slots empty, and never lets
# a held key pay the fee or pre-sign an operator-led rotation.
class Solana::VaultUpdateSignersServerCosignersTest < ActiveSupport::TestCase
  def vault = @vault ||= Solana::Vault.new(client: CosignFakeClient.build)

  # [pubkey_b58, filled?] per signature slot, in account order.
  def slots(wire)
    raw = Base64.decode64(wire)
    count = raw.getbyte(0) # < 128 signers, so one compact-u16 byte
    sigs = Array.new(count) { |i| raw.byteslice(1 + i * 64, 64) }
    message = raw.byteslice(1 + count * 64..)
    # Legacy message: 3 header bytes, compact-u16 key count, then the keys.
    keys = Array.new(message.getbyte(3)) { |i| Solana::Keypair.encode_base58(message.byteslice(4 + i * 32, 32)) }
    keys.first(count).zip(sigs.map { |s| s != ("\x00" * 64).b })
  end

  test "a held cosigner is signed on the server; Phantom's slot stays empty; admin pays" do
    held = Solana::Keypair.generate
    phantom = Solana::Keypair.generate.to_base58
    admin = Solana::Keypair.admin.to_base58

    result = Solana::Config.stub(:governance?, false) do
      vault.build_update_signers(new_signers: [admin, held.to_base58, phantom],
                                 lead_signer: admin, cosigner_pubkey: held.to_base58,
                                 extra_cosigners: [phantom], server_cosigners: [held])
    end

    filled = slots(result[:serialized_tx]).to_h
    assert_equal admin, slots(result[:serialized_tx]).first.first, "admin is account 0, the fee payer"
    assert filled[admin]
    assert filled[held.to_base58], "the held key signed on the server"
    refute filled[phantom], "Phantom's slot is left for Phantom"
    assert_equal [held.to_base58], result[:server_cosigned]
    refute_includes result.to_s, Solana::Keypair.encode_base58(held.to_bytes), "no secret in the result"
  end

  test "without held keys the build is the shape that shipped" do
    phantom = Solana::Keypair.generate.to_base58
    admin = Solana::Keypair.admin.to_base58
    result = Solana::Config.stub(:governance?, false) do
      vault.build_update_signers(new_signers: [admin, phantom, Solana::Keypair.generate.to_base58],
                                 lead_signer: admin, cosigner_pubkey: phantom)
    end
    assert_equal [], result[:server_cosigned]
    assert_equal [true, false], slots(result[:serialized_tx]).map(&:last)
  end

  test "a held key cannot pre-sign an operator-led rotation" do
    held = Solana::Keypair.generate
    lead = Solana::Keypair.generate.to_base58
    error = assert_raises(ArgumentError) do
      Solana::Config.stub(:governance?, false) do
        vault.build_update_signers(new_signers: [lead, held.to_base58, Solana::Keypair.generate.to_base58],
                                   lead_signer: lead, cosigner_pubkey: held.to_base58,
                                   server_cosigners: [held])
      end
    end
    assert_match(/only a rotation the server leads/, error.message)
  end

  test "a held key that is not an authorizer is refused" do
    stray = Solana::Keypair.generate
    admin = Solana::Keypair.admin.to_base58
    phantom = Solana::Keypair.generate.to_base58
    assert_raises(ArgumentError) do
      Solana::Config.stub(:governance?, false) do
        vault.build_update_signers(new_signers: [admin, phantom, stray.to_base58],
                                   lead_signer: admin, cosigner_pubkey: phantom, server_cosigners: [stray])
      end
    end
  end
end
