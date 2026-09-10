# frozen_string_literal: true

require "test_helper"

# [integration] The turf-totals board, RENDERED through the real request stack,
# arrives on a document that carries everything its entry call now depends on.
#
# WHY A REQUEST AND NOT A SOURCE READ. /tasks/route-board-through-runner moved
# the board's return address, cluster, transport fork and handoff watch into
# window.tmWalletOp, which the LAYOUT renders (shared/_wallet_op_runner), and the
# flow itself was already registered by name from the layout
# (shared/_contest_entry_intent). So the board is now correct only on a page
# that renders all three together. A source read of any one file cannot say
# that; a layout that stopped rendering the runner would leave every source test
# green and every hold-to-confirm throwing "tmWalletOp is not a function" — on
# the app's highest-traffic money path, after the user has picked a lineup.
class BoardEntryRunnerRenderTest < ActionDispatch::IntegrationTest
  setup { @contest = contests(:one) }

  def contest_page
    get contest_path(@contest)
    follow_redirect! while response.redirect?
    assert_response :success
    assert_includes response.body, "selectionBoard(",
                    "this contest no longer renders the turf-totals board — the test is aimed at the wrong page"
    response.body
  end

  # The rendered confirmEntry, bounded by the method after it — the same bounds
  # test/lib/board_entry_call_site_js_test.rb lifts it by.
  def rendered_confirm_entry(body)
    start = body.index("async confirmEntry() {")
    assert start, "the rendered board carries no confirmEntry"
    finish = body.index("showError(message) {", start)
    assert finish, "could not bound the rendered confirmEntry"
    body[start...finish]
  end

  test "the board renders beside the runner and the intent its entry call needs" do
    body = contest_page

    assert_includes body, "window.tmWalletOp = function (name, ctx, opts)",
                    "the page renders the board but not the runner it calls — every on-chain " \
                    "entry throws before a wallet is asked"
    assert_includes body, "S.walletOps.define('contest_entry'",
                    "the page renders no contest_entry registration — the runner would carry " \
                    "the trip to a wallet and nothing could finish it"
    assert_includes rendered_confirm_entry(body), "window.tmWalletOp('contest_entry'",
                    "the rendered board does not route its entry through the runner"
  end

  test "the rendered entry call writes none of the address book the runner owns" do
    code = rendered_confirm_entry(contest_page).lines.reject { |l| l =~ %r{\A\s*//} }.join

    %w[redirectLink appUrl solanaCluster /auth/phantom/callback 'pagehide' walletOps.run(].each do |token|
      assert_not_includes code, token,
                          "the board's rendered entry spells out #{token} itself again — the " \
                          "address book written twice, which is how a hand-rolled site lost an entry"
    end
  end
end
