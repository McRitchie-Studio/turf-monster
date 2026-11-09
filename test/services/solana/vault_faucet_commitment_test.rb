require "test_helper"

# [unit] The RPC commitment options on the faucet path (Vault#ensure_ata, #mint_spl).
#
# WHY. ensure_ata returns once its create is CONFIRMED. The client's defaults are
# the RPC's, "finalized", about 32 slots (~13s) behind. A mint sent with a default
# preflight simulates against finalized state, where the new ATA does not exist
# yet, and the RPC refuses it. A finalized ATA read says "missing" for an account
# that exists, so a repeat call sends a second create and its IllegalOwner rescue
# re-read at finalized and raised. e2e/devnet-smoke.spec.js used to hide both
# behind a 5s sleep and a retry (task turf-e2e-remaining-race-fixes, review by
# Carl and Jasper). These tests pin the options a fake client receives; no RPC.
class Solana::VaultFaucetCommitmentTest < ActiveSupport::TestCase
  # A client that records every call and answers like a devnet RPC would.
  class RecordingClient
    attr_reader :calls

    def initialize(account_exists: false, create_error: nil)
      @calls = []
      @account_exists = account_exists
      @create_error = create_error
    end

    def get_account_info(pubkey, **opts)
      @calls << [:get_account_info, opts]
      { "value" => (@account_exists ? { "lamports" => 2_039_280 } : nil) }
    end

    def get_latest_blockhash(**opts)
      @calls << [:get_latest_blockhash, opts]
      "11111111111111111111111111111111"
    end

    def send_and_confirm(_wire, **opts)
      @calls << [:send_and_confirm, opts]
      if @create_error
        error, @create_error = @create_error, nil
        @account_exists = true
        raise error
      end
      "sig#{@calls.size}"
    end
  end

  WALLET = Solana::Keypair.generate.to_base58

  def mint = Solana::Config::USDC_MINT

  test "ensure_ata reads the account at confirmed" do
    client = RecordingClient.new(account_exists: true)
    result = Solana::Vault.new(client: client).ensure_ata(WALLET, mint: mint)

    assert_equal false, result[:created]
    assert_equal [[:get_account_info, { commitment: "confirmed" }]], client.calls
  end

  test "ensure_ata's IllegalOwner rescue re-reads at confirmed and treats the account as created" do
    client = RecordingClient.new(create_error: Solana::Client::RpcError.new("Transaction failed: IllegalOwner"))
    result = Solana::Vault.new(client: client).ensure_ata(WALLET, mint: mint)

    assert_equal false, result[:created]
    reads = client.calls.select { |name, _| name == :get_account_info }
    assert_equal [{ commitment: "confirmed" }, { commitment: "confirmed" }], reads.map(&:last)
  end

  test "mint_spl builds on a confirmed blockhash and skips the finalized preflight" do
    client = RecordingClient.new
    Solana::Vault.new(client: client).mint_spl(1_000_000, mint: mint, to: WALLET)

    assert_includes client.calls, [:get_latest_blockhash, { commitment: "confirmed" }]
    assert_includes client.calls, [:send_and_confirm, { skip_preflight: true }]
  end
end
