require "test_helper"

# Unit — Admin::FreeEntriesRefreshJob is the OFF-request warm-up for the
# free-entries admin table (which renders CACHE-FIRST). It must:
#   - refresh the denormalized users.seeds/level mirror from sync_balance,
#   - read the entry-token list (which warms entry_tokens:<address>), and
#   - skip wallet-less users and survive a per-user RPC flake.
class Admin::FreeEntriesRefreshJobTest < ActiveJob::TestCase
  # A vault stand-in that records the addresses it read and pins the seeds
  # sync_balance returns, so we can prove the job warmed both data paths without
  # touching the network.
  class RecordingVault < FakeVault
    attr_reader :list_entry_tokens_calls, :sync_balance_calls

    def initialize(seeds: 0, **opts)
      super(**opts)
      @seeds = seeds
      @list_entry_tokens_calls = []
      @sync_balance_calls = []
    end

    def sync_balance(address, **_opts)
      @sync_balance_calls << address
      { seeds: @seeds, level: User.level_for(@seeds) }
    end

    def list_entry_tokens(address, **_opts)
      @list_entry_tokens_calls << address
      []
    end
  end

  setup do
    @user = users(:sam) # web3_solana_address fixture → solana_connected?
  end

  test "refreshes the denormalized seeds mirror and reads the entry-token list" do
    @user.update_column(:seeds, 0)
    vault = RecordingVault.new(seeds: 350)

    Solana::Vault.stub :new, vault do
      Admin::FreeEntriesRefreshJob.perform_now([@user.id])
    end

    @user.reload
    assert_equal 350, @user.seeds, "job must write fresh seeds to the denormalized mirror"
    assert_equal 4, @user.level, "level must be recomputed from the fresh seeds (350 → level 4)"
    assert_includes vault.list_entry_tokens_calls, @user.solana_address,
      "job must read the entry-token list off-request to warm entry_tokens:<address>"
  end

  test "skips users without a wallet address — no RPC" do
    vault = RecordingVault.new(seeds: 100)

    Solana::Vault.stub :new, vault do
      Admin::FreeEntriesRefreshJob.perform_now([users(:jordan).id]) # no solana address
    end

    assert_empty vault.sync_balance_calls, "wallet-less user must not trigger sync_balance"
    assert_empty vault.list_entry_tokens_calls, "wallet-less user must not trigger a token scan"
  end

  test "an RPC flake on a user is rescued and never fails the batch" do
    flaky = Class.new(FakeVault) do
      def sync_balance(*, **)
        raise Solana::Client::RpcError, "simulated RPC flake"
      end
    end.new

    Solana::Vault.stub :new, flaky do
      assert_nothing_raised do
        Admin::FreeEntriesRefreshJob.perform_now([@user.id])
      end
    end
  end
end
