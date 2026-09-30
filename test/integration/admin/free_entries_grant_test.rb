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

  # ── The "your free entry is ready" email ─────────────────────────────────

  def ready_emails
    EmailDelivery.where(email_key: "FreeEntryMailer#ready")
  end

  test "a confirmed grant sends exactly one entry-ready email to the player" do
    log_in_as(@admin)
    @signup.update_columns(email: "fan@example.com")

    Solana::Vault.stub :new, FakeVault.new(tokens: []) do
      assert_difference -> { ready_emails.count }, 1 do
        post admin_grant_free_entries_path(user_slug: @signup.slug, minted: 0)
      end
    end

    delivery = ready_emails.last
    assert_equal "fan@example.com", delivery.to
    assert_equal @signup, delivery.user
  end

  test "the email links the contest the player's signup page promoted" do
    log_in_as(@admin)
    @signup.update_columns(email: "fan@example.com")
    page = LandingPage.create!(name: "TikTok", slug: "tiktok", contest: contests(:one), active: true)

    Solana::Vault.stub :new, FakeVault.new(tokens: []) do
      post admin_grant_free_entries_path(user_slug: @signup.slug, minted: 0)
    end

    args = ActiveJob::Arguments.deserialize(ready_emails.last.args)
    assert_equal [@signup, page.contest], args
  end

  test "a mint that fails on chain sends no email" do
    log_in_as(@admin)
    @signup.update_columns(email: "fan@example.com")
    vault = FakeVault.new(tokens: [])
    vault.raise_on_mint = StandardError.new("simulated chain failure")

    Solana::Vault.stub :new, vault do
      assert_no_difference -> { ready_emails.count } do
        post admin_grant_free_entries_path(user_slug: @signup.slug, minted: 0)
      end
    end
    assert_match(/Grant failed/, flash[:alert])
  end

  test "a refused grant (count mismatch, the double-click) sends no email" do
    log_in_as(@admin)
    @signup.update_columns(email: "fan@example.com")

    Solana::Vault.stub :new, FakeVault.new(tokens: [a_token]) do
      assert_no_difference -> { ready_emails.count } do
        post admin_grant_free_entries_path(user_slug: @signup.slug, minted: 0)
      end
    end
  end

  test "a player with no email is granted, and the operator is told no email went" do
    log_in_as(@admin)
    @signup.update_columns(email: nil)
    vault = FakeVault.new(tokens: [])

    Solana::Vault.stub :new, vault do
      assert_no_difference -> { ready_emails.count } do
        post admin_grant_free_entries_path(user_slug: @signup.slug, minted: 0)
      end
    end
    assert_equal 1, vault.mint_calls.length
    assert_match(/no email address/, flash[:alert])
  end

  test "an email that fails to enqueue does not report the landed mint as failed" do
    log_in_as(@admin)
    @signup.update_columns(email: "fan@example.com")

    Studio::Email.stub :deliver, ->(*, **) { raise "SMTP down" } do
      Solana::Vault.stub :new, FakeVault.new(tokens: []) do
        post admin_grant_free_entries_path(user_slug: @signup.slug, minted: 0)
      end
    end
    assert_equal "Granted 1 free entry to #{@signup.display_name}", flash[:notice]
    assert_match(/entry landed, but its email/, flash[:alert])
  end
end
