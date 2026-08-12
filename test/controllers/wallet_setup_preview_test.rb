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
    # The modal reloads the page itself; the server-side prompt is one-shot and
    # already spent, so the reload must carry the modal with it or the user lands
    # on a bare page mid-flow.
    layout = Rails.root.join("app/views/layouts/application.html.erb").read
    assert_includes layout, "walletSetupReopen",
                    "the layout must reopen the modal after the modal's own reload"
    assert_match(/if \(el\) el\.remove\(\)/, layout,
                 "the reopen path has no marker tag — removing it unguarded would throw")
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
