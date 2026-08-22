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

  def controller_for(user, onchain: true)
    ApplicationController.new.tap do |c|
      c.define_singleton_method(:current_user) { user }
      c.define_singleton_method(:onchain_session?) { onchain }
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

  test "combo account counts tokens from the wallet that can sign this session" do
    managed = "ManagedCount#{SecureRandom.hex(8)}"
    phantom = "PhantomCount#{SecureRandom.hex(8)}"
    @user.update_columns(web2_solana_address: managed, web3_solana_address: phantom)

    with_memory_cache do
      Rails.cache.write(Solana::Vault.entry_tokens_cache_key(managed), [
        { consumed: false }
      ])
      Rails.cache.write(Solana::Vault.entry_tokens_cache_key(phantom), [
        { consumed: false }, { consumed: false }
      ])

      assert_equal 1, controller_for(@user, onchain: false).send(:display_entry_token_count),
                   "a web2 session must promise only tokens its managed signer can consume"
      assert_equal 2, controller_for(@user, onchain: true).send(:display_entry_token_count),
                   "a web3 session must promise only tokens its Phantom signer can consume"
    end
  end

  test "session refresh hydrates the token count from the active signer wallet" do
    managed = "ManagedHydrate#{SecureRandom.hex(8)}"
    phantom = "PhantomHydrate#{SecureRandom.hex(8)}"
    @user.update_columns(web2_solana_address: managed, web3_solana_address: phantom)
    seen_token_address = nil

    fake_vault = Object.new
    fake_vault.define_singleton_method(:fetch_wallet_balances) { |_| nil }
    fake_vault.define_singleton_method(:sync_balance) { |_| nil }
    fake_vault.define_singleton_method(:list_entry_tokens) do |address|
      seen_token_address = address
      []
    end

    result = Solana::Vault.stub(:new, fake_vault) do
      controller_for(@user, onchain: false).send(:fetch_navbar_hydrate, @user)
    end

    assert_equal managed, seen_token_address,
                 "refreshSession must not overwrite the web2 store with Phantom-owned tokens"
    assert_equal 0, result[:entry_token_count]
  end
end
