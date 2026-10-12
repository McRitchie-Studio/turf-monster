require "test_helper"

# [unit] Solana::Keypair.cosigners — SOLANA_COSIGNER_KEYS, the window-only
# server-held vault cosigners the v0.26 `contests:nfl_sunday_lock` signs with.
class Solana::KeypairCosignersTest < ActiveSupport::TestCase
  def secret(keypair) = Solana::Keypair.encode_base58(keypair.to_bytes)

  test "absent or blank is no cosigner, not a raise" do
    assert_equal [], Solana::Keypair.cosigners({})
    assert_equal [], Solana::Keypair.cosigners("SOLANA_COSIGNER_KEYS" => " , ")
  end

  test "comma-separated base58 secrets load in order" do
    a = Solana::Keypair.generate
    b = Solana::Keypair.generate
    loaded = Solana::Keypair.cosigners("SOLANA_COSIGNER_KEYS" => " #{secret(a)} ,#{secret(b)}")
    assert_equal [a.address, b.address], loaded.map(&:address)
  end

  test "a repeated key is refused by public key, never echoing a secret" do
    a = Solana::Keypair.generate
    error = assert_raises(ArgumentError) do
      Solana::Keypair.cosigners("SOLANA_COSIGNER_KEYS" => "#{secret(a)},#{secret(a)}")
    end
    assert_includes error.message, a.address
    refute_includes error.message, secret(a)
  end

  test "the admin key is refused: it already signs as admin" do
    error = assert_raises(ArgumentError) do
      Solana::Keypair.cosigners("SOLANA_COSIGNER_KEYS" => secret(Solana::Keypair.admin))
    end
    assert_includes error.message, Solana::Keypair.admin.address
  end
end
