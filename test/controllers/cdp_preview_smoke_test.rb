require "test_helper"

# Render smoke for the cdp-ramp preview: /admin/modals/preview/cdp-ramp renders
# through the modal_preview layout, which ships shared/_alpine_factories so
# cdpRampFlow — inline-only, no importmap duplicate — exists in the iframe.
#
# WAS TWO SMOKES. The other asserted /admin/modals LISTED the "CDP ramp
# (Coinbase)" variant group; it was retired with the gallery on 2026-09-09, and
# what it proved has no subject any more — the card lives in turf's own
# style-guide section now and is asserted there against the real partial.
class CdpPreviewSmokeTest < ActionDispatch::IntegrationTest
  test "cdp-ramp preview renders via the modal_preview layout with the factory inline" do
    log_in_as users(:alex)
    get admin_modal_preview_path(
      modal_id: "cdp-ramp",
      props: { flow: "sell", step: "send", walletMode: "web2", demoCountdownMinutes: 27 }.to_json
    )
    assert_response :success
    assert_includes response.body, "window.cdpRampFlow"
    assert_includes response.body, "Send your USDC to Coinbase"
  end
end
