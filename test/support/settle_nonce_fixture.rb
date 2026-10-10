require "minitest/mock"

# A settle wire built over a stand-in RPC: a fixed recent blockhash and a
# fixed nonce account. The admin key is the test seed, so every signature is
# deterministic and a wire can be pinned by its digest.
module SettleNonceFixture
  COSIGNER = Solana::Keypair.from_bytes(Digest::SHA256.digest("settle-nonce cosigner"))
  THIRD = Solana::Keypair.from_bytes(Digest::SHA256.digest("settle-nonce third signer"))
  NONCE_ACCOUNT = Solana::Keypair.from_bytes(Digest::SHA256.digest("settle-nonce account")).to_base58
  BLOCKHASH = Solana::Keypair.encode_base58((1..32).to_a.pack("C*"))
  NONCE_VALUE_BYTES = (101..132).to_a.pack("C*")
  NONCE_VALUE = Solana::Keypair.encode_base58(NONCE_VALUE_BYTES)
  ADVANCE_NONCE = [4].pack("V")

  SETTLEMENTS = [
    { wallet: Solana::Keypair.from_bytes(Digest::SHA256.digest("winner 1")).to_base58, entry_num: 1, rank: 1, payout: 30_000_000 },
    { wallet: Solana::Keypair.from_bytes(Digest::SHA256.digest("winner 2")).to_base58, entry_num: 2, rank: 2, payout: 10_000_000 }
  ].freeze

  def nonce_account_data(authority)
    [1, 1].pack("VV") + Solana::Keypair.decode_base58(authority) + NONCE_VALUE_BYTES + [5000].pack("Q<")
  end

  def fake_client(authority: COSIGNER.to_base58)
    data = Base64.strict_encode64(nonce_account_data(authority))
    client = Object.new
    client.define_singleton_method(:get_latest_blockhash) { |commitment: "finalized"| BLOCKHASH }
    client.define_singleton_method(:get_account_info) do |pubkey, **_opts|
      raise "unexpected account read #{pubkey}" unless pubkey == NONCE_ACCOUNT

      { "value" => { "data" => [data, "base64"] } }
    end
    client
  end

  def vault
    Solana::Vault.new(client: fake_client)
  end

  def durable_nonce(authority = COSIGNER.to_base58)
    { pubkey: NONCE_ACCOUNT, authority: authority }
  end

  def build(governance: false, nonce: nil, authority: COSIGNER.to_base58)
    Solana::Config.stub(:governance?, governance) do
      kwargs = { cosigner_pubkey: COSIGNER.to_base58, extra_cosigners: governance ? [THIRD.to_base58] : [] }
      kwargs[:durable_nonce] = durable_nonce(authority) if nonce
      vault.build_settle_contest("settle-nonce-contest", SETTLEMENTS, **kwargs)
    end
  end

  def parse(result)
    Solana::WireMessage.parse_base64(result.fetch(:serialized_tx))
  end

  def key(bytes)
    Solana::Keypair.encode_base58(bytes)
  end
end
