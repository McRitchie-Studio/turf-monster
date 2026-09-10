require "test_helper"

# BOTH logout links, ONE helper.
#
# They used to carry the SAME inline onclick, copy-pasted — and the copies had
# already drifted in a way that mattered: the gear link had `data-turbo="false"`
# and the /account one did not, so one logout was a full document load and the
# other was a Turbo visit that left every in-memory Alpine store intact.
#
# `data-turbo="false"` is LOAD-BEARING, not decoration: wipeClientState clears
# storage but deliberately does not re-initialise Alpine stores, because a full
# document load rebuilds them from their declarations — stronger than any re-init
# the helper could write, and it cannot drift as stores are added. That is only
# true if logout actually reloads the document, which is what these assert.
class LogoutLinksTest < ActionDispatch::IntegrationTest
  test "every logout link calls the shared wipe on a full document load" do
    log_in_as users(:alex)
    get account_path
    assert_response :success

    # /account renders BOTH: the gear sidebar's (from the layout) and the
    # account page's own button. Asserting over ALL of them rather than two
    # named ones is deliberate — a third added later is covered by construction,
    # and it was a difference BETWEEN two copies that produced the bug.
    links = Nokogiri::HTML(response.body).css("a[href='#{logout_path}']")
    assert_operator links.size, :>=, 2,
                    "expected at least the gear-sidebar and account-page logout links"

    links.each_with_index do |link, i|
      assert_includes link["onclick"].to_s, "wipeClientState",
                      "logout link ##{i} must call the SHARED helper, not a copy-pasted removeItem"
      assert_equal "false", link["data-turbo"],
                   "logout link ##{i} must force a full document load — that is what rebuilds " \
                   "every Alpine store from its declaration, which the wipe deliberately does " \
                   "not do itself. The gear link had this and the account link did not, so the " \
                   "two logouts did not even navigate the same way."
    end
  end

  test "no logout link still carries the old hand-rolled removeItem" do
    log_in_as users(:alex)
    get account_path
    assert_response :success
    Nokogiri::HTML(response.body).css("a[href='#{logout_path}']").each do |link|
      refute_includes link["onclick"].to_s, "removeItem",
                      "a logout link is still clearing ONE key by hand. That was one key of " \
                      "nineteen; the helper clears both stores."
    end
  end
end
