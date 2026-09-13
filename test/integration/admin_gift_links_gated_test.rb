require "test_helper"

# The operator asked for two things in one breath: put "Send Free Entry" and
# "Emails" where he can reach them, AND make sure both the UI and the backend are
# admin-gated. Those are one contract, so they are tested as one.
#
# WHY BOTH HALVES MATTER. Hiding a link is not access control — a non-admin who
# types the URL must still be refused — and refusing the URL is not discovery: an
# admin who cannot find the page does not use it. A test for either alone passes
# for a broken version of the other.
class AdminGiftLinksGatedTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @player = users(:sam)
    assert @admin.admin?, "fixture precondition"
    assert_not @player.admin?, "fixture precondition"
  end

  # --- discovery: an admin can actually FIND them ---

  test "the admin dashboard links to both pages" do
    log_in_as(@admin)
    get admin_dashboard_path

    assert_response :success
    assert_select "a[href=?]", admin_entry_gifts_path
    assert_select "a[href=?]", admin_emails_path
  end

  test "the gear sidebar carries both for an admin" do
    log_in_as(@admin)
    get root_path
    follow_redirect! while response.redirect?

    assert_response :success
    assert_select "a[href=?]", admin_entry_gifts_path
    assert_select "a[href=?]", admin_emails_path
  end

  # --- the UI gate: a player is shown neither ---

  test "a non-admin sees no gift or email link anywhere in the chrome" do
    log_in_as(@player)
    get root_path
    follow_redirect! while response.redirect?

    assert_response :success
    # The page rendered — so a zero count here is the GATE, not an empty body.
    assert_select "nav", minimum: 1
    assert_select "a[href=?]", admin_entry_gifts_path, count: 0
    assert_select "a[href=?]", admin_emails_path, count: 0
  end

  # --- the BACKEND gate: hiding the link is not access control ---
  #
  # Every route of the gift console, not just #index — a write left ungated is
  # the one that mints real money-equivalent tokens.

  test "a non-admin is refused every entry-gift route" do
    log_in_as(@player)
    gift = EntryGift.create!(recipient_email: "friend@example.com", sender: @admin)

    assert_no_difference -> { EntryGift.count } do
      get admin_entry_gifts_path
      assert_response :redirect, "index must refuse a non-admin"

      post admin_entry_gifts_path, params: { recipient_email: "sneaky@example.com" }
      assert_response :redirect, "create must refuse a non-admin"

      post admin_resend_entry_gift_path(gift)
      assert_response :redirect, "resend must refuse a non-admin"

      post admin_retry_mint_entry_gift_path(gift)
      assert_response :redirect, "retry_mint must refuse a non-admin"
    end
  end

  test "a signed-out visitor is refused the gift console" do
    get admin_entry_gifts_path
    assert_response :redirect
  end

  # /admin/emails is drawn by studio-engine, not this app, so its gate is the
  # GEM's. Asserted here anyway: this app links to it now, and a gem bump that
  # relaxed it would otherwise be discovered by a player rather than by CI.
  test "a non-admin is refused the engine's email manager" do
    log_in_as(@player)
    get admin_emails_path
    assert_response :redirect
  end
end
