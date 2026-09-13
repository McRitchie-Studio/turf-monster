require "test_helper"

# [integration] The username_rename intent reaches the RENDERED page, from the
# layout, on a route that has nothing to do with renaming.
#
# WHAT THIS TIER OWNS AND THE OTHERS CANNOT. The unit and component tests read
# the partial off disk; both stay green if the layout never renders it. That is
# not a hypothetical failure — it is the EXACT blocker the contest-entry flow
# shipped: the registration lived in the contest board, the board renders on two
# contest pages, and the wallet returns to neither. Entries were silently lost.
# This asserts the wiring that fix depends on, for the second intent.
#
# THE ROUTE CHOICE IS THE ASSERTION. A page that has no rename UI on it must
# still carry the handlers, because the document the wallet returns to has no
# rename UI either.
class UsernameRenameIntentLayoutTest < ActionDispatch::IntegrationTest
  def body_for(path)
    get path
    follow_redirect! while response.redirect?
    assert_response :success
    response.body
  end

  # Read the SCRIPT CONTENT, not the whole document. Every assertion below is
  # about JavaScript that must be parsed and executed by the browser; a match
  # anywhere else in the HTML would answer a different question.
  def script_text(html)
    Nokogiri::HTML(html).css("script:not([src])").map(&:text).join("\n")
  end

  # ASSERT A BOOLEAN, NOT A SUBSTRING-IN-BLOB. assert_includes prints the haystack
  # on failure, and the haystack here is every inline script in the document —
  # hundreds of kilobytes that bury the one sentence saying what broke.
  def assert_js(js, needle, message)
    assert js.include?(needle), "#{message} (looked for #{needle.inspect} in #{js.length} chars of inline script)"
  end

  test "a signed-out page already carries both intent handlers" do
    js = script_text(body_for(root_path))

    assert_js js, "window.tmPrepareUsernameRename",
                 "prepare is missing — a rename started here would journal nothing to resume"
    assert_js js, "window.tmCompleteUsernameRename",
                 "complete is missing — the wallet's return leg has nothing to call"
    assert_js js, "walletOps.define('username_rename'",
                 "the handlers exist but are not registered under the name the journal carries"
  end

  test "a signed-in account page carries them too" do
    log_in_as(users(:alex))
    js = script_text(body_for(account_path))

    assert_js js, "walletOps.define('username_rename'", "the intent is not registered on the account page"
    assert_js js, "window.tmUsernameFinalize",
                 "the engine's finalize_hook is looked up on window by NAME — modals/_username names it"
  end

  test "the finalize URL is emitted as a real path, resolved by the router" do
    # The route helper is evaluated at RENDER time, so this is the only tier that
    # can see what it actually produced. A helper that stopped resolving would
    # emit an empty string here and the redirect transport would POST to the page
    # it is already on.
    js = script_text(body_for(root_path))

    assert_js js, %(window.tmUsernameRenameFinalizeUrl = "#{confirm_username_account_path}"),
                 "the emitted finalize URL does not match what the router resolves"
    assert_match %r{\Aconfirm/?|\A/}, confirm_username_account_path
    refute_equal "", confirm_username_account_path
  end

  test "the layout renders the rename intent independently of the entry intent" do
    # THE CONTROL. Both partials are rendered from the same two lines of the
    # layout, so a change that drops one block drops both — and every assertion
    # above would go red together, reading as one broken feature rather than a
    # broken layout. Naming the sibling here says which.
    js = script_text(body_for(root_path))

    assert_js js, "walletOps.define('contest_entry'", "missing from the rendered page"
    assert_js js, "walletOps.define('username_rename'", "missing from the rendered page"
  end
end
