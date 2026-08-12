require "test_helper"

# Component render of the wallet-setup modal (web3-only onboarding), driven
# through the admin modal gallery — the same seam cdp_preview_smoke_test uses.
#
# What this tier owns: the modal is REGISTERED, it renders, and it carries the
# three things the operator specified — the Phantom row, the "New to Solana
# Wallets?" teaching block with both screenshots side by side, and the guide CTA.
class WalletSetupPreviewTest < ActionDispatch::IntegrationTest
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
