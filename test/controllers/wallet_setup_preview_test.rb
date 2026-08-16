require "test_helper"

# Component render of the wallet-setup modal (web3-only onboarding), driven
# through the admin modal gallery — the same seam cdp_preview_smoke_test uses.
#
# What this tier owns: the modal is REGISTERED, it renders, and it carries the
# three things the operator specified — the Phantom row, the "New to Solana
# Wallets?" teaching block with both screenshots side by side, and the guide CTA.
class WalletSetupPreviewTest < ActionDispatch::IntegrationTest
  # The failure mode no other assertion in this file can see.
  #
  # The modal's x-data is a DOUBLE-QUOTED HTML attribute. One double-quote
  # character inside it — trivially easy to type in a code comment — closes the
  # attribute early, and Alpine then mounts the whole component as a silent
  # no-op: the markup still renders, so every `assert_includes response.body`
  # below still PASSES while the modal is dead in a real browser. It regressed
  # the auth modal once (PR #30) and it regressed this one during development;
  # both times only a browser caught it.
  #
  # This reads the source rather than the response because that is where the
  # defect lives, and it is the cheapest place to fail loudly.
  test "the wallet-setup x-data attribute contains no double quotes" do
    source = Rails.root.join("app/views/modals/_wallet_setup.html.erb").read
    x_data = source[/<div x-data="(.*?)"\s*\n\s*class=/m, 1]
    assert x_data.present?, "could not locate the x-data attribute — did the root element change?"
    assert_not_includes x_data, '"',
                        "a double quote inside the double-quoted x-data closes it early and " \
                        "silently kills the modal in the browser (markup assertions won't catch it)"
  end

  test "admin modal gallery lists the wallet-setup variant" do
    log_in_as users(:alex)
    get admin_modals_path
    assert_response :success
    assert_includes response.body, "Set up your wallet (post-auth)"
    assert_includes response.body, "modals/_wallet_setup.html.erb"
  end

  test "wallet-setup preview renders the Phantom row in both states" do
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "wallet-setup")
    assert_response :success

    assert_includes response.body, "Set up your wallet"
    # Installed → Connect; not installed → the install page. Both branches ship
    # in the markup; Alpine picks between them at mount on hasPhantom.
    assert_includes response.body, "@click=\"connect()\""
    assert_includes response.body, "https://phantom.com/download"
    assert_includes response.body, "#se-wallet-phantom"
  end

  test "wallet-setup preview ships the self-updating install row" do
    # The install row has to carry the user to a wallet with no instruction to
    # follow: a spinner while it waits, then it flips itself to the Installed
    # badge. Two mechanisms behind that, because neither is sufficient alone —
    # the ping catches every case where the provider CAN appear without a reload,
    # and the automatic reload covers the case where it cannot (Chrome does not
    # inject a newly-installed extension into an already-open tab).
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "wallet-setup")
    assert_response :success

    # Spinner + Waiting…, armed by leaving for the install page.
    assert_includes response.body, "installClicked = true"
    assert_includes response.body, "installClicked ? 'Waiting…' : 'Install'"
    assert_includes response.body, "cta-spinner"
    assert_includes response.body, "updates on its own"
    # The ping.
    assert_includes response.body, "self._stopPoll()"
    # The automatic reload, and its guards: only after they left to install, and
    # at most once (or a focus loop reloads the page forever).
    assert_includes response.body, "walletSetupAutoReloaded"
    assert_includes response.body, "walletSetupReopen"
    assert_includes response.body, "visibilitychange"
    # Listeners torn down, so reopening the modal can't stack them.
    assert_includes response.body, "removeEventListener"
    # Detected state uses the same green badge as the wallet-connect picker.
    assert_includes response.body, "badge border-primary text-primary"
    # What Connect actually does, for someone who just met Phantom.
    assert_includes response.body, "sign a message proving the"
    # The instruction the operator rejected must be gone.
    assert_not_includes response.body, "Reload page"
    assert_not_includes response.body, "Installed it?"
  end

  test "the post-reload reopen path is wired in the layout" do
    # The modal reloads the page itself when the user returns from installing
    # Phantom; the server-side prompt is one-shot and already spent, so the
    # reload must carry the modal with it or the user lands on a bare page
    # mid-flow.
    #
    # Assert the CONTRACT (a sessionStorage key drives the reopen), not the shape
    # of the code around it: this test used to pin `if (el) el.remove()`, and it
    # went red the moment the onboarding chain took over the FIRST open and that
    # branch stopped reading a marker tag at all — a passing behaviour reported
    # as a failure. What matters is that a reopen key exists and the chain driver
    # owns the first open.
    layout = Rails.root.join("app/views/layouts/application.html.erb").read
    assert_includes layout, "walletSetupReopen",
                    "the layout must reopen the modal after the modal's own reload"
    assert_includes layout, "onboarding-chain-data",
                    "the chain driver owns the first open; this path is the return trip only"
  end

  test "wallet-setup preview renders the teaching block with both screenshots" do
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "wallet-setup")
    assert_response :success

    assert_includes response.body, "New to Solana Wallets?"
    assert_includes response.body, "/phantom-step-download.png"
    assert_includes response.body, "/phantom-step-create-wallet.png"
    # Side by side, per the operator's spec — a 2-column grid, not stacked.
    assert_includes response.body, "grid grid-cols-2"
    assert_includes response.body, "Read the setup guide"
  end

  test "both onboarding screenshots are actually served" do
    # The modal hard-links these public/ paths; a missing file is a broken
    # teaching block that no markup assertion above would catch.
    ["phantom-step-download.png", "phantom-step-create-wallet.png"].each do |file|
      path = Rails.public_path.join(file)
      assert path.exist?, "public/#{file} is missing — the wallet-setup modal links it"
      assert path.size.positive?, "public/#{file} is empty"
    end
  end

  test "wallet-setup carries the small link back to Buy an Entry Token" do
    # Web3-only onboarding put this modal where Buy an Entry Token used to land,
    # and the operator asked for a way back to it. Small and quiet by design —
    # linking Phantom is the season's path — but it has to WORK, so pin the swap
    # target rather than the wording.
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "wallet-setup")
    assert_response :success

    assert_includes response.body, "Buy an entry token"
    assert_includes response.body, "$store.modals.swap('buy-entry-token', {})",
                    "the link must swap (one card on screen), not stack a second modal"
  end

  test "the buy-token link is gated on a wallet, and says why when there isn't one" do
    # THE BLOCKER this modal shipped with (2026-08-15): every entry-token rail
    # refuses a wallet-less buyer — TokensController#stripe_checkout redirects
    # with "Connect a wallet first." (navigating them off the contest) and
    # #coinflow_order 422s the same string into a window.alert — because a token
    # has to be minted somewhere. Web3-only onboarding made THAT the modal's main
    # audience, so the link dead-ended for exactly the people looking at it.
    #
    # Operator's call was to keep it VISIBLE and explain rather than refuse. Both
    # branches ship in the markup; Alpine picks between them on walletConnected.
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "wallet-setup")
    assert_response :success

    assert_includes response.body, %(<template x-if="$store.session.walletConnected">),
                    "the clickable rail must be gated on actually having a wallet"
    assert_includes response.body, %(<template x-if="!$store.session.walletConnected">)
    assert_includes response.body, "Link a wallet first",
                    "a wallet-less player must be told why, not handed a dead button"
  end

  test "the gate reads solana_connected?, not the mode that lies about it" do
    # `mode` reads "web2" for a WALLET-LESS account (it is the funding-rail
    # audience, not a claim that a wallet exists), so branching the link on mode
    # would show the button to precisely the people the rails refuse. The session
    # payload publishes the same predicate the rails guard on.
    user = users(:jordan)
    user.update_columns(web2_solana_address: nil, web3_solana_address: nil)
    log_in_as user
    get contests_path
    assert_response :success
    payload = JSON.parse(response.body[/id="session-context"[^>]*>(\{.*?\})<\/script>/m, 1])

    assert_equal false, payload["walletConnected"], "no wallet of either kind"
    assert_equal "web2", payload["mode"],
                 "and mode says web2 anyway — which is exactly why it cannot be the gate"

    user.update_columns(web2_solana_address: "GrandfatheredManaged#{user.id}")
    get contests_path
    payload = JSON.parse(response.body[/id="session-context"[^>]*>(\{.*?\})<\/script>/m, 1])
    assert_equal true, payload["walletConnected"],
                 "a grandfathered managed wallet CAN buy a token — the link is for them"
  end

  test "the token rails really do refuse a wallet-less buyer" do
    # The other half of the claim above, asserted against the endpoints rather
    # than trusted from a comment. If these ever stop refusing, the gate in the
    # modal becomes unnecessary and this test says so out loud.
    user = users(:jordan)
    user.update_columns(web2_solana_address: nil, web3_solana_address: nil)
    log_in_as user

    post tokens_coinflow_order_path, params: { pack: "single" }, as: :json
    assert_response :unprocessable_entity
    assert_equal "Connect a wallet first.", JSON.parse(response.body)["error"]

    post tokens_stripe_checkout_path, params: { pack: "single" }
    assert_redirected_to tokens_buy_path
    assert_equal "Connect a wallet first.", flash[:alert]
  end

  test "the buy-entry-token modal the link swaps to is registered in the layout" do
    # The swap above is a dead button unless the host registers that id. It is
    # registered UNGATED, so this holds for any user who can reach the modal —
    # and it is the half of the link no markup assertion on the modal can see.
    layout = Rails.root.join("app/views/layouts/application.html.erb").read
    assert_includes layout, "$store.modals.current().id === 'buy-entry-token'",
                    "wallet-setup swaps to buy-entry-token; the host must register it"
  end

  test "the guide CTA falls back to Phantom's guide until /getting-started ships" do
    # The house guide is a SEPARATE task (phantom-onboarding-guide-page). This
    # asserts the seam, not a particular winner: whichever target resolves, the
    # CTA must be a real destination — never a dead route.
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "wallet-setup")
    assert_response :success

    if Rails.application.routes.url_helpers.respond_to?(:getting_started_path)
      assert_includes response.body, "/getting-started",
                      "with the guide route live the CTA should point at the house guide"
    else
      assert_includes response.body, WalletSetupHelper::PHANTOM_GUIDE_URL,
                      "without the guide route the CTA must fall back to Phantom's guide, not 404"
    end
  end
end
