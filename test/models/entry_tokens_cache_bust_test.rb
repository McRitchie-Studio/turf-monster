require "test_helper"

# User#bust_entry_tokens_cache! — the write-time invalidation every entry-token
# WRITER calls after its chain TX confirms (TokenPurchaseJob mint,
# TokensController, ContestsController's three entry-confirm paths).
#
# There are TWO caches behind "does this wallet hold an entry token?", and the
# outer one WRAPS the inner one:
#
#   User#cached_entry_tokens          → "entry_tokens/v1/<prog8>/<addr>"
#     └── Vault#list_entry_tokens     → "entry_tokens:<addr>"   ← the RPC layer
#
# The inner key is also the one the navbar 🎟️ badge and the "Hold for Free
# Entry" CTA read DIRECTLY (ApplicationController#display_entry_token_count →
# Solana::Vault.entry_tokens_cache_key). Deleting only the outer key left the
# inner one warm, so the very next read re-entered #list_entry_tokens, hit the
# still-warm RPC layer, and served the SPENT token as unconsumed for up to 60s.
#
# The user-visible failure that caused: after a Phantom entry burned a token the
# button still said "Hold for Free Entry", and a second #prepare_entry re-picked
# the CONSUMED token and built a doomed enter_contest_with_token (0x177f)
# instead of falling back to USDC — the exact promise-outliving-the-token
# failure the board view's own comment claims the binding prevents.
class EntryTokensCacheBustTest < ActiveSupport::TestCase
  setup do
    @user = users(:sam) # web3_solana_address fixture → solana_connected?
  end

  # The test env runs :null_store (every read is nil), so a cache assertion
  # needs a real store injected — same pattern as display_entry_token_count_test.
  def with_memory_cache(&block)
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new, &block)
  end

  def vault_key(address)
    Solana::Vault.entry_tokens_cache_key(address)
  end

  def warm_both_layers(user, address, tokens)
    Rails.cache.write(user.entry_tokens_cache_key, tokens)
    Rails.cache.write(vault_key(address), tokens)
  end

  # --- the defect, stated directly --------------------------------------------

  test "the bust clears the RPC layer the navbar badge and the CTA read" do
    with_memory_cache do
      warm_both_layers(@user, @user.web3_solana_address, [{ pda: "tpda_proof", consumed: false }])

      @user.bust_entry_tokens_cache!

      assert_nil Rails.cache.read(vault_key(@user.web3_solana_address)),
                 "bust_entry_tokens_cache! must delete Vault#list_entry_tokens' key too — it is " \
                 "the key the badge and the hold-for-free-entry CTA read, and the key the outer " \
                 "User layer re-reads on its next miss"
    end
  end

  # CONTROL: the layer that was already cleared. If this ever goes red the
  # harness is watching the wrong keys, not the bust.
  test "the bust still clears the User layer (control)" do
    with_memory_cache do
      warm_both_layers(@user, @user.web3_solana_address, [{ pda: "tpda_proof", consumed: false }])

      @user.bust_entry_tokens_cache!

      assert_nil Rails.cache.read(@user.entry_tokens_cache_key)
    end
  end

  test "the bust clears BOTH wallets on a combo account" do
    with_memory_cache do
      @user.web2_solana_address = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"
      warm_both_layers(@user, @user.web3_solana_address, [{ consumed: false }])
      Rails.cache.write(vault_key(@user.web2_solana_address), [{ consumed: false }])

      @user.bust_entry_tokens_cache!

      assert_nil Rails.cache.read(vault_key(@user.web3_solana_address)), "Phantom wallet layer"
      assert_nil Rails.cache.read(vault_key(@user.web2_solana_address)), "managed wallet layer"
    end
  end

  # --- the consequence, at the surface that lied -------------------------------

  test "after the bust the navbar badge reads loading, not a stale count" do
    with_memory_cache do
      warm_both_layers(@user, @user.web3_solana_address, [{ pda: "tpda_proof", consumed: false }])

      controller = ApplicationController.new
      user = @user
      controller.define_singleton_method(:current_user) { user }
      controller.define_singleton_method(:onchain_session?) { true }

      assert_equal 1, controller.send(:display_entry_token_count),
                   "precondition: the badge sees the unspent token"

      @user.bust_entry_tokens_cache!

      # #display_entry_token_count memoizes per request, so the honest read is
      # the NEXT request — a fresh controller instance, as production gets.
      fresh = ApplicationController.new
      fresh.define_singleton_method(:current_user) { user }
      fresh.define_singleton_method(:onchain_session?) { true }
      assert_nil fresh.send(:display_entry_token_count),
                 "a spent token must leave the badge in the cold-cache 'loading' state, " \
                 "never showing a stale count the wallet can no longer honour"
    end
  end

  test "the memoized per-request reads are dropped too" do
    with_memory_cache do
      @user.instance_variable_set(:@cached_entry_tokens, [{ consumed: false }])
      @user.instance_variable_set(:@entry_token_balance, 1)

      @user.bust_entry_tokens_cache!

      refute @user.instance_variable_defined?(:@cached_entry_tokens)
      refute @user.instance_variable_defined?(:@entry_token_balance)
    end
  end
end
