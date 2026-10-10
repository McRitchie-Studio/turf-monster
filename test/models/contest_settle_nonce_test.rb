require "test_helper"

# [unit] Contest#settle_onchain! QUEUES THE SETTLE ITS CLUSTER SELECTS.
#
# Off (the checked-in config): the queued row is byte for byte what
# origin/accepted queued. On: the row is nonce-anchored and names its nonce.
class ContestSettleNonceTest < ActiveSupport::TestCase
  include SettleNonceFixture

  # SHA-256 of the queued row's serialized_tx and its metadata, from this
  # fixture on origin/accepted 013595f8.
  DEFAULT_ROW_SHA256 = "1fe0bff91969965bdf9bef8241a8c1a3a645aba638aa4d655a3427620b7957e9".freeze
  DEFAULT_METADATA = { settlements: SettleNonceFixture::SETTLEMENTS }.to_json.freeze

  setup do
    @contest = Contest.create!(name: "Nonce settle row", slate: slates(:one), rank: 9000 + rand(900),
                               contest_type: "standard", starts_at: 1.hour.ago, user: users(:alex),
                               status: "open", max_entries: 29)
    Contest.where(id: @contest.id).update_all(slug: "nonce-settle-row", onchain_contest_id: "OnchainPda1111111111111111111111111111111111")
    @contest.reload
    settlements = SETTLEMENTS
    @contest.define_singleton_method(:payout_settlements) { settlements }
  end

  def queue_settle(settings: nil)
    Solana::Config.stub(:governance?, false) do
      Solana::Vault.stub(:new, vault) do
        Solana::SettleNonce.stub(:current, settings) { @contest.settle_onchain! }
      end
    end
    PendingTransaction.where(target: @contest, tx_type: "settle_contest").sole
  end

  test "off: the queued settle row is what origin/accepted queued" do
    row = queue_settle

    assert_equal DEFAULT_ROW_SHA256, Digest::SHA256.hexdigest(Base64.strict_decode64(row.serialized_tx))
    assert_equal DEFAULT_METADATA, row.metadata
    refute row.nonce_anchored?
  end

  test "on: the row is nonce-anchored, cosigned by the CLI key, and names its nonce" do
    settings = Solana::SettleNonce::Settings.new(network: "devnet", nonce_account: NONCE_ACCOUNT,
                                                 cosigner: COSIGNER.to_base58)
    row = queue_settle(settings: settings)
    wire = Solana::WireMessage.parse_base64(row.serialized_tx)

    assert row.nonce_anchored?
    assert_equal({ "account" => NONCE_ACCOUNT, "authority" => COSIGNER.to_base58, "value" => NONCE_VALUE }, row.durable_nonce)
    assert_equal ADVANCE_NONCE, wire.instructions.first[:data]
    assert_equal NONCE_VALUE, wire.recent_blockhash_base58
    assert wire.signer?(COSIGNER.public_key_bytes)
    refute wire.signer?(Solana::Keypair.decode_base58(Solana::Config::MULTISIG_COSIGNER)), "the Phantom cosigner has no slot"
  end
end
