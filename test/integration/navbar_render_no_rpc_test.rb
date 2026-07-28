require "test_helper"
require "minitest/mock"

# Regression for the navbar RPC-load residual (after PR #92).
#
# PR #92 already moved the wallet balance + seeds off the render path
# (display_balance / display_seeds_data are Rails.cache.read-only, hydrated
# client-side). The residual: perform_solana_preload STILL joined two
# synchronous Solana RPCs on every logged-in HTML render —
#   1. the entry-token COUNT (list_entry_tokens, a getProgramAccounts scan),
#   2. the admin vault_state (read_vault_state) for admins.
# Both blocked first paint on a cold 60s cache. This proves those residual
# reads are cache-first too: the render path issues NO synchronous Solana RPC,
# and a cache-miss renders a loading/nil badge — never a hang or a 500.
#
# Cache store: the test env runs :null_store (reads always nil), which would
# MASK a cache-first read (it can never be "warm"). Each test injects a real,
# COLD MemoryStore so the cache-first path is exercised for real — the same
# injected-store pattern as display_balance_test.rb.
class NavbarRenderNoRpcTest < ActionDispatch::IntegrationTest
  # A Solana::Vault stand-in whose two navbar reads are TRIPWIRES: any call
  # means a synchronous RPC leaked onto the render path. It subclasses FakeVault
  # so every OTHER method the render might touch returns a benign default (no
  # surprise NoMethodError that would mask the real assertion). Each tripwire
  # counts the call AND raises: the count proves the call happened, and the
  # render still returning 200 proves the render path does not DEPEND on the
  # fetch succeeding (fail-safe cache-miss = loading badge).
  class RenderPathRpcTripwire < FakeVault
    def list_entry_tokens_calls
      @list_entry_tokens_calls || 0
    end

    def read_vault_state_calls
      @read_vault_state_calls || 0
    end

    def list_entry_tokens(*, **)
      @list_entry_tokens_calls = (@list_entry_tokens_calls || 0) + 1
      raise "list_entry_tokens hit on the render path (synchronous getProgramAccounts scan)"
    end

    def read_vault_state(*, **)
      @read_vault_state_calls = (@read_vault_state_calls || 0) + 1
      raise "read_vault_state hit on the render path (synchronous RPC)"
    end
  end

  def with_cold_memory_cache(&block)
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new, &block)
  end

  test "logged-in wallet render issues NO synchronous entry-token RPC (cache-first count)" do
    log_in_as(users(:sam)) # web3_solana_address fixture → solana_connected?

    tripwire = RenderPathRpcTripwire.new
    with_cold_memory_cache do
      Solana::Vault.stub :new, tripwire do
        # The contests index renders the navbar but has NO on-chain body read,
        # so the ONLY Solana reads on this render are the navbar's — isolating
        # the preload/navbar path from a page body's legitimate live funding
        # re-derive (which reads list_entry_tokens by design, out of scope).
        get contests_path
        follow_redirect! while response.redirect?
      end
    end

    assert_response :success,
      "cold-cache render must not hang or 500 when the entry-token RPC is unavailable"
    assert_equal 0, tripwire.list_entry_tokens_calls,
      "navbar render path must read the entry-token count cache-first — no synchronous list_entry_tokens scan"
  end

  test "admin render issues NO synchronous vault_state RPC (cache-first drop)" do
    # Promote the wallet fixture to admin so the preload runs its admin-only
    # vault_state branch on the same navbar-clean index page.
    admin = users(:sam) # web3_solana_address fixture → solana_connected?
    admin.update!(role: "admin")
    assert admin.admin?, "sam must be promoted to admin for this regression"
    log_in_as(admin)

    tripwire = RenderPathRpcTripwire.new
    with_cold_memory_cache do
      Solana::Vault.stub :new, tripwire do
        get contests_path
        follow_redirect! while response.redirect?
      end
    end

    assert_response :success,
      "admin cold-cache render must not hang or 500 when vault_state is unavailable"
    assert_equal 0, tripwire.read_vault_state_calls,
      "admin navbar render must read vault_state cache-first — no synchronous read_vault_state on a non-vault page"
    assert_equal 0, tripwire.list_entry_tokens_calls,
      "admin navbar render must also read the entry-token count cache-first"
  end
end
