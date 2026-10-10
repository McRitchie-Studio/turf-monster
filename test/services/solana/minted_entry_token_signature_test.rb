require "test_helper"

# [unit] Solana::Vault#minted_entry_token_signature: what TokenPurchaseJob asks
# before it sends a mint. The token account for a source_ref is read at
# `confirmed`; a token that is there answers the signature that minted it.
class Solana::MintedEntryTokenSignatureTest < ActiveSupport::TestCase
  REF = "stripe:42:1".freeze

  def vault_over(**chain)
    client = FakeSolanaClient.new({}, **chain)
    [Solana::Vault.new(client: client), client]
  end

  def token_pda
    Solana::Keypair.encode_base58(Solana::Vault.new(client: nil).entry_token_pda(REF).first)
  end

  def token_account = { "value" => { "owner" => Solana::Config::PROGRAM_ID, "lamports" => 1 } }

  test "no token account: nil, read at confirmed" do
    vault, client = vault_over

    assert_nil vault.minted_entry_token_signature(REF)
    assert_equal ["confirmed"], client.account_info_commitments
  end

  test "lamports at the address are not a token: nil" do
    vault, = vault_over(account_infos: { token_pda => { "value" => { "owner" => ChainFixtures::SYSTEM_PROGRAM, "lamports" => 5 } } })

    assert_nil vault.minted_entry_token_signature(REF)
  end

  test "a token that is there answers the mint that created it, never dust on its address" do
    pda = token_pda
    vault, = vault_over(
      account_infos: { pda => token_account },
      signatures: { pda => [{ "signature" => "later-dust", "err" => nil }, { "signature" => "the-mint", "err" => nil },
                            { "signature" => "earlier-dust", "err" => nil }] },
      transactions: { "later-dust" => ChainFixtures.dust_transfer(pda), "earlier-dust" => ChainFixtures.dust_transfer(pda),
                      "the-mint" => ChainFixtures.program_transaction("mint_entry_token", signer: "AnyAdminKey", account: pda) }
    )

    assert_equal "the-mint", vault.minted_entry_token_signature(REF)
  end

  test "a token whose mint cannot be read raises: the caller neither sends nor records a guess" do
    pda = token_pda
    vault, = vault_over(account_infos: { pda => token_account },
                        signatures: { pda => [{ "signature" => "the-mint", "err" => nil }] },
                        transactions: { "the-mint" => nil })

    error = assert_raises(Solana::Client::RpcError) { vault.minted_entry_token_signature(REF) }
    assert_match(/cannot be read yet/, error.message)
  end

  test "an account read that fails raises; it is not read as no token" do
    vault, = vault_over(account_info_raises: true)

    assert_raises(Solana::Client::RpcError) { vault.minted_entry_token_signature(REF) }
  end
end
