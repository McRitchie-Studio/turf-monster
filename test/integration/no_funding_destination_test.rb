require "test_helper"

# The no_funding blocker's destination, asserted across the seam it crosses.
#
# Solana::ErrorInterpreter EMITS the blocker reason; the contest board HANDLES
# it. Those are two artifacts that can drift apart silently, and the comments in
# the interpreter had already drifted — they named Top Up Wallet, a modal the
# board has not sent that blocker to for some time. This test ties the two ends
# together so the prose in error_interpreter.rb (pinned by
# error_interpreter_claims_test.rb) stays anchored to what the page does.
#
# NOT INERT, and that is the point: the expected reason is RECOMPUTED by calling
# the service, and the thing it is checked against is the RENDERED page. Neither
# side is derived from the other, so re-wiring either one turns this red.
#
# It asserts the wiring at the render boundary — the case arm and the
# dispatcher's own body. The live Alpine handoff is the tracked Playwright gap
# shared with wallet_topup_test.rb and web2_entry_token_funding_test.rb.
class NoFundingDestinationTest < ActionDispatch::IntegrationTest
  # The reason string comes from the service, not from a literal typed here.
  def interpreter_no_funding_reason
    Solana::ErrorInterpreter.interpret("No entry tokens. Buy at /tokens/buy")[:blocker][:reason]
  end

  test "the reason the interpreter emits is the reason the board routes to the funds dispatcher" do
    reason = interpreter_no_funding_reason
    assert_equal "no_funding", reason,
                 "sanity: the service is the source of this reason string"

    get contest_path(contests(:one))
    assert_response :success

    assert_match(/case '#{Regexp.escape(reason)}':\s+this\.showFundsNeeded\(\);/, response.body,
                 "the board must answer the interpreter's #{reason} blocker through showFundsNeeded")
  end

  test "the board never routes the interpreter's blocker into Top Up Wallet" do
    reason = interpreter_no_funding_reason

    get contest_path(contests(:one))
    assert_response :success

    refute_match(/case '#{Regexp.escape(reason)}':\s+this\.showWalletTopup\(\);/, response.body,
                 "#{reason} must not route to Top Up Wallet — showWalletTopup has no caller at head, " \
                 "and the comments in error_interpreter.rb are written on that fact")
  end

  test "the funds dispatcher's own body offers Get USDC and Buy an Entry Token, and never Top Up Wallet" do
    get contest_path(contests(:one))
    assert_response :success

    body = response.body
    dispatcher = body[/showFundsNeeded\(\)\s*\{.*?\n    \},/m]
    # Anti-vacuity: a nil or tiny slice would pass every refute below.
    refute_nil dispatcher, "showFundsNeeded's body must be on the rendered contest page"
    assert_operator dispatcher.length, :>, 200,
                    "the slice must be the real dispatcher body, not a truncated match"

    assert_includes dispatcher, "this.showBuyEntryToken();",
                    "the USDC kill-switch audience's branch must be in the dispatcher"
    assert_includes dispatcher, "this.showGetUsdc();",
                    "everyone else's branch must be in the dispatcher"
    refute_includes dispatcher, "showWalletTopup",
                    "the dispatcher must not reach Top Up Wallet on either branch"
  end
end
