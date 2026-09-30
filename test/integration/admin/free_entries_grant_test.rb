require "test_helper"

# "Grant 1" on /admin/free_entries — the operator's discretionary hand-mint.
#
# #mint pays only what levels have earned, so a brand-new TikTok signup (0 seeds,
# 0 owed) had no way to receive the free entry the video promised. #grant mints
# exactly one, whatever the level arithmetic says, and only when the chain still
# shows the minted count the operator was looking at.
class Admin::FreeEntriesGrantTest < ActionDispatch::IntegrationTest
  setup do
    @admin  = users(:alex)
    @signup = users(:sam)
    @signup.update_columns(seeds: 0, reference: "tiktok", slug: "sam-grant")
  end

  def a_token
    { pda: "pda-x", source_ref: "operator:x:1", source: 0, consumed: false, created_at: 1 }
  end

  test "mints exactly one operator-ref token for a user who is owed nothing" do
    log_in_as(@admin)
    vault = FakeVault.new(tokens: [])

    Solana::Vault.stub :new, vault do
      post admin_grant_free_entries_path(user_slug: @signup.slug, minted: 0)
    end

    assert_redirected_to admin_free_entries_path
    assert_equal 1, vault.mint_calls.length, "a grant is ONE entry"
    assert_match(/\Aoperator:#{@signup.id}:/, vault.mint_calls.first,
      "a grant has no level behind it, so it takes the operator ref, never a levelup ref")
    assert_equal [@signup.solana_address], vault.mint_wallets
    assert_equal "Granted 1 free entry to #{@signup.display_name}", flash[:notice]
  end

  test "refuses when the chain holds more than the operator was shown" do
    # The double-click case: the first submit landed a token, so the second
    # reads minted 1 against a shown 0 and must mint nothing.
    log_in_as(@admin)
    vault = FakeVault.new(tokens: [a_token])

    Solana::Vault.stub :new, vault do
      post admin_grant_free_entries_path(user_slug: @signup.slug, minted: 0)
    end

    assert_empty vault.mint_calls
    assert_match(/Nothing was minted/, flash[:alert])
    assert_redirected_to admin_free_entries_path
  end

  test "refuses a grant that names no shown count" do
    log_in_as(@admin)
    vault = FakeVault.new(tokens: [])

    Solana::Vault.stub :new, vault do
      post admin_grant_free_entries_path(user_slug: @signup.slug)
    end

    assert_empty vault.mint_calls, "without the shown count the confirm binds nothing"
  end

  test "a failed chain read mints nothing and says why" do
    log_in_as(@admin)
    vault = FakeVault.new(tokens: [])
    def vault.list_entry_tokens(*, **) = raise(StandardError, "RPC timeout")

    Solana::Vault.stub :new, vault do
      assert_difference -> { ErrorLog.count }, 1 do
        post admin_grant_free_entries_path(user_slug: @signup.slug, minted: 0)
      end
    end

    assert_empty vault.mint_calls
    assert_match(/Grant failed: RPC timeout/, flash[:alert])
    assert_redirected_to admin_free_entries_path
  end

  test "keeps the source filter on the redirect" do
    log_in_as(@admin)

    Solana::Vault.stub :new, FakeVault.new(tokens: []) do
      post admin_grant_free_entries_path(user_slug: @signup.slug, minted: 0, reference: "tiktok")
    end

    assert_redirected_to admin_free_entries_path(reference: "tiktok")
  end

  test "a non-admin cannot grant" do
    player = users(:casey)
    refute player.admin?, "the case needs a non-admin"
    log_in_as(player)
    vault = FakeVault.new(tokens: [])

    Solana::Vault.stub :new, vault do
      post admin_grant_free_entries_path(user_slug: @signup.slug, minted: 0)
    end

    assert_empty vault.mint_calls
    refute_equal "Granted 1 free entry to #{@signup.display_name}", flash[:notice]
  end
end
