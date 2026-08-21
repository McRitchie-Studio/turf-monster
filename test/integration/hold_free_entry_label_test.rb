require "test_helper"

# Component tier for the contest board's hold-to-confirm CTA (task: hold-for-free-entry).
#
# The operator's ask is CONFIDENCE AT THE MOMENT OF THE HOLD: a user whose wallet
# holds an entry token should read "Hold for Free Entry" and know the entry spends
# that token rather than their balance — not discover it in the receipt afterward.
#
# The label is BOUND to $store.session.tokensAvailable rather than server-rendered,
# and that is the part worth pinning: the count is re-read by refreshSession() after
# every on-chain success, so the label falls back to "Hold to Confirm" the instant
# the token is spent. A baked label would keep promising a free entry for the SECOND
# entry of the same page view.
#
# Alpine evaluates the binding in the browser, so what this tier owns is that the
# binding SHIPS on BOTH buttons, reads the token count, and carries no mode gate.
# The live swap between the two copies is asserted in a real browser by
# e2e/free_entry_web3.spec.js.
#
# ASSERTED SEMANTICALLY, NOT VERBATIM. An earlier version of this file pinned the
# whole expression as one string, which quietly made the test a mirror of
# whatever guard shipped — it agreed with the code by construction and could not
# have caught the guard being wrong (Carl, PR #386). Each clause is asserted for
# what it MEANS instead.
class HoldFreeEntryLabelTest < ActionDispatch::IntegrationTest
  # The first <li> of each .hold-btn is the idle label — the engine's hold_button
  # renders default_text there (studio/_hold_button).
  BINDINGS = /<li><span x-text="([^"]*)"><\/span><\/li>/

  def board_label_bindings
    get contest_path(contests(:one))
    assert_response :success
    response.body.scan(BINDINGS).flatten
  end

  test "both board hold buttons bind their label to the entry-token count" do
    bindings = board_label_bindings

    assert_equal 2, bindings.size,
                 "the desktop + mobile board hold buttons must BOTH bind the CTA label — " \
                 "one bound and one baked is the regression a single assert_includes misses"
    bindings.each_with_index do |b, i|
      assert_includes b, "$store.session.tokensAvailable",
                      "button ##{i + 1} must read the live token count"
      assert_includes b, "Hold for Free Entry", "button ##{i + 1} must offer the free-entry copy"
      assert_includes b, "Hold to Confirm",     "button ##{i + 1} must fall back to the default copy"
    end
  end

  # Acceptance criterion 2 — "shown whenever the wallet holds an unconsumed entry
  # token". WHENEVER is the whole claim: no mode test. Both entry paths spend a
  # token now (managed via #resolve_web2_entry_funding!, Phantom via
  # #prepare_entry), so narrowing this back to one mode would make the CTA lie to
  # the other — which is exactly the direction this task was blocked over. If that
  # narrowing is ever deliberate, the criterion moves first and this test with it.
  test "the label is not gated on the session mode" do
    board_label_bindings.each_with_index do |b, i|
      assert_no_match(/isWeb2|isWeb3|\.mode\b/, b,
                      "button ##{i + 1} must show the free-entry copy for ANY wallet holding a token")
    end
  end

  test "the board ships no baked Hold to Confirm label beside the binding" do
    get contest_path(contests(:one))
    assert_response :success

    assert_not_includes response.body, "<li>Hold to Confirm</li>",
                        "a baked idle label means one board button never swaps to the free-entry copy"
  end

  # The promise has to survive the NEXT screen too. The wallet-signing modal used
  # to name a currency transfer unconditionally, so a user who held "Hold for Free
  # Entry" was immediately asked to "Approve the USDC transfer" for a transaction
  # that transfers no USDC (it is enter_contest_with_token). The copy now follows
  # prepare_entry's `token_funded` — the SERVER's own funding decision, which had
  # no consumer until this.
  test "the signing modal names a free entry when the server funded it with a token" do
    get contest_path(contests(:one))
    assert_response :success

    assert_includes response.body, "prepareData.token_funded",
                    "the signing-modal copy must branch on the server's funding decision, " \
                    "not on the currency the user happened to pick"
    assert_includes response.body, "Approve your free entry in your wallet",
                    "a token-funded entry must be named as free at the moment of signing"
    assert_includes response.body, "transfer in your wallet",
                    "the currency-funded entry keeps its own copy"
  end

  # The in-modal buttons render only inside the auth wizard (behind
  # entry_funding_mode), so a contest page-render can't see them — but the
  # exclusion is deliberate and worth a guard, so pin it where the defect would
  # be typed. Same precedent as wallet_setup_preview_test.rb reading the source.
  test "the post-purchase in-modal hold buttons keep a literal label" do
    %w[
      app/views/modals/auth/_tokens.html.erb
      app/views/modals/auth/_paypal_tokens.html.erb
    ].each do |rel|
      source = Rails.root.join(rel).read
      assert_includes source, 'default_text: "Hold to Confirm Entry"',
                      "#{rel} follows a token PURCHASE — telling that buyer the entry is " \
                      "free would be false, so it must keep its own literal label"
    end
  end
end
