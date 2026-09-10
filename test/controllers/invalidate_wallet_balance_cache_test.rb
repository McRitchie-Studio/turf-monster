# frozen_string_literal: true

require "test_helper"

# ApplicationController#invalidate_wallet_balance_cache — the both-keys drop for
# an action that has already MOVED the user's money.
#
# WHY IT IS NOT #invalidate_usdc_cache. The navbar pill renders usdc + usdt
# COMBINED, and #combined_balance returns nil — the "loading" state the client
# then fills via refreshBalance — only when BOTH reads are nil; a nil beside a
# live value counts as ZERO. The two keys are written together on the same 60s
# TTL, so the USDT twin is warm essentially whenever the USDC one is. Dropping
# USDC alone therefore does not yield "loading"; it yields the USDT balance
# presented as the total — a confidently wrong number, and a worse failure than
# the stale one it replaced.
#
# Unit-style on a bare controller instance, following display_balance_test.rb:
# the test env runs :null_store (reads always nil), so Rails.cache is stubbed to
# a MemoryStore.
class InvalidateWalletBalanceCacheTest < ActiveSupport::TestCase
  setup do
    @user = users(:sam) # web3_solana_address fixture → solana_connected?
  end

  def controller_for(user)
    ApplicationController.new.tap do |c|
      c.define_singleton_method(:current_user) { user }
    end
  end

  def with_memory_cache(&block)
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new, &block)
  end

  def warm_both(usdc:, usdt:)
    Rails.cache.write("usdc_balance:#{@user.id}", usdc, expires_in: 60.seconds)
    Rails.cache.write("usdt_balance:#{@user.id}", usdt, expires_in: 60.seconds)
  end

  test "drops BOTH balance keys, so the pill reads cache-cold" do
    with_memory_cache do
      warm_both(usdc: 1284.0, usdt: 0.0)
      controller = controller_for(@user)

      controller.send(:invalidate_wallet_balance_cache)

      assert_nil Rails.cache.read("usdc_balance:#{@user.id}")
      assert_nil Rails.cache.read("usdt_balance:#{@user.id}")
      assert_nil controller.send(:display_balance),
                 "both keys cold must render the LOADING state, which refreshBalance then fills"
    end
  end

  # THE TEST THAT JUSTIFIES THE METHOD'S EXISTENCE.
  #
  # It pins the failure of the obvious one-key fix. If someone later 'simplifies'
  # invalidate_wallet_balance_cache back to invalidate_usdc_cache, the test above
  # still passes whenever USDT happens to be 0 — because 0.0 is not nil, but
  # 0 + 0 renders as a plausible-looking total. This one gives USDT a NON-ZERO
  # value, so the one-key drop produces a visibly wrong number instead.
  test "the one-key drop would render USDT alone AS THE TOTAL" do
    with_memory_cache do
      warm_both(usdc: 1284.0, usdt: 7.0)
      controller = controller_for(@user)

      controller.send(:invalidate_usdc_cache) # the INSUFFICIENT drop

      assert_equal 7.0, controller.send(:display_balance),
                   "with USDT still warm, dropping USDC alone reports $7 as the wallet total — " \
                   "not a loading state, and not the truth. This is why the both-keys method exists."
    end
  end

  test "is a no-op-safe repeat" do
    with_memory_cache do
      warm_both(usdc: 1284.0, usdt: 7.0)
      controller = controller_for(@user)

      controller.send(:invalidate_wallet_balance_cache)
      controller.send(:invalidate_wallet_balance_cache)

      assert_nil controller.send(:display_balance)
    end
  end
end
