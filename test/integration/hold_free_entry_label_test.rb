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
# binding SHIPS on BOTH buttons and that no baked label ships beside it. The live
# swap is a tracked Playwright gap — the same precedent as the hold-window funding
# pre-check assertions in wallet_topup_test.rb.
class HoldFreeEntryLabelTest < ActionDispatch::IntegrationTest
  # The attribute as it lands in the response: Rails escapes the expression into
  # the double-quoted attribute, and the browser hands Alpine back the original.
  BOUND_LABEL = "x-text=\"$store.session.tokensAvailable &gt;= 1 ? " \
                "&#39;Hold for Free Entry&#39; : &#39;Hold to Confirm&#39;\"".freeze

  test "both board hold buttons bind their label to the entry-token count" do
    get contest_path(contests(:one))
    assert_response :success

    assert_equal 2, response.body.scan(BOUND_LABEL).size,
                 "the desktop + mobile board hold buttons must BOTH bind the CTA label — " \
                 "one bound and one baked is the regression a single assert_includes misses"
  end

  test "the board ships no baked Hold to Confirm label beside the binding" do
    get contest_path(contests(:one))
    assert_response :success

    assert_not_includes response.body, "<li>Hold to Confirm</li>",
                        "a baked idle label means one board button never swaps to the free-entry copy"
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
