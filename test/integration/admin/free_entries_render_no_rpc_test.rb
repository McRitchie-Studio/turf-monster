require "test_helper"
require "minitest/mock"

# Regression for the free-entries perf bug (cache-free-entries-rpc).
#
# /admin/free_entries WAS the slowest local page (~869ms). The old
# Admin::FreeEntriesController#compute_user_data_for spawned two live Solana
# RPCs per listed user (sync_balance + list_entry_tokens) ON THE RENDER PATH —
# ~820ms of blocking network. The fix copies the navbar's cache-first pattern:
# render reads Rails.cache only (seeds from the denormalized users.seeds mirror,
# entry-token counts from Solana::Vault.entry_tokens_cache_key), a cold row
# renders a "syncing" loading state, and a background job warms the cache.
#
# The test env's :null_store would MASK a cache-first read (never "warm"), so —
# like navbar_render_no_rpc_test — each test injects a real MemoryStore.
class Admin::FreeEntriesRenderNoRpcTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  # A Solana::Vault stand-in whose reads are TRIPWIRES: any call means a
  # synchronous RPC leaked onto the render path. Subclasses FakeVault so every
  # other method returns a benign default (no NoMethodError masking the assert).
  class RenderPathRpcTripwire < FakeVault
    def sync_balance(*, **)
      raise "sync_balance hit on the render path (blocking RPC)"
    end

    def list_entry_tokens(*, **)
      raise "list_entry_tokens hit on the render path (getProgramAccounts scan)"
    end
  end

  setup do
    @admin       = users(:alex)  # role: admin, has email → log_in_as
    @wallet_user = users(:sam)   # web3_solana_address → the one users_with_wallet row
    # Denormalized on-chain mirror the render reads for seeds/level — floor(250/100)=2.
    # Real users have a slug (the mint / "Act as" row buttons route on it); the
    # fixture skips the slug-generation callback, so set one here.
    @wallet_user.update_columns(seeds: 250, slug: "sam-test")
  end

  def tokens_key
    Solana::Vault.entry_tokens_cache_key(@wallet_user.solana_address)
  end

  test "cold cache renders with ZERO render-path RPC, a loading row, and enqueues a warm job" do
    log_in_as(@admin)

    Rails.stub :cache, ActiveSupport::Cache::MemoryStore.new do # cold
      Solana::Vault.stub :new, RenderPathRpcTripwire.new do
        assert_enqueued_with(job: Admin::FreeEntriesRefreshJob) do
          get admin_free_entries_path
        end
      end
    end

    assert_response :success,
      "cold-cache render must not hang or 500 when on-chain reads are unavailable"
    assert_select "td", { text: "250" },
      "seeds must render from the denormalized mirror — no RPC"
    assert_match "syncing…", response.body,
      "a cold row must render a loading state, not a misleading authoritative 0"
  end

  test "warm cache renders accurate counts with ZERO render-path RPC" do
    log_in_as(@admin)

    store = ActiveSupport::Cache::MemoryStore.new
    # One unconsumed entry token cached → minted 1; owed = floor(250/100) - 1 = 1.
    store.write(tokens_key, [{ consumed: false }])

    Rails.stub :cache, store do
      Solana::Vault.stub :new, RenderPathRpcTripwire.new do
        get admin_free_entries_path
      end
    end

    assert_response :success
    assert_match "Mint 1", response.body,
      "a warm row (owed 1) must offer the Mint button computed from cached counts"
    refute_match "syncing…", response.body,
      "a warm row must not render the loading state"
  end
end
