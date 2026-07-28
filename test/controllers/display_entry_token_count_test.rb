require "test_helper"
require "minitest/mock"

# ApplicationController#display_entry_token_count — the navbar 🎟️ badge count,
# made cache-first (same contract as #display_balance) so the render path never
# issues a getProgramAccounts scan:
#   - warm cache → the non-consumed count from the cached entry-token LIST
#   - cold cache → nil ("loading"; the client repaints via updateNavTokens)
#   - guest / non-wallet → definitive 0
#
# It reads the SAME cache key list_entry_tokens writes and mint/consume
# invalidate (Solana::Vault#entry_tokens_cache_key), so the badge stays
# correct post-action without adding a third cache key.
#
# Unit-style on a bare controller instance with current_user pinned. The
# cache-backed branch needs a real store — the test env runs :null_store
# (reads always nil) — so Rails.cache is stubbed to a MemoryStore per the
# injected-store pattern (see display_balance_test.rb).
class DisplayEntryTokenCountTest < ActiveSupport::TestCase
  setup do
    @user = users(:sam) # web3_solana_address fixture → solana_connected?
    @cache_key = Solana::Vault.new.entry_tokens_cache_key(@user.solana_address)
  end

  def controller_for(user)
    ApplicationController.new.tap do |c|
      c.define_singleton_method(:current_user) { user }
    end
  end

  def with_memory_cache(&block)
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new, &block)
  end

  test "cache cold → nil (loading state preserved, no RPC)" do
    with_memory_cache do
      assert_nil controller_for(@user).send(:display_entry_token_count)
    end
  end

  test "warm cache → count of NON-consumed tokens only" do
    with_memory_cache do
      Rails.cache.write(@cache_key, [
        { consumed: false }, { consumed: true }, { consumed: false }
      ])
      assert_equal 2, controller_for(@user).send(:display_entry_token_count)
    end
  end

  test "warm cache with an empty list → definitive 0" do
    with_memory_cache do
      Rails.cache.write(@cache_key, [])
      assert_equal 0, controller_for(@user).send(:display_entry_token_count)
    end
  end

  test "guest → definitive 0 (no cache read)" do
    with_memory_cache do
      assert_equal 0, controller_for(nil).send(:display_entry_token_count)
    end
  end
end
