require "test_helper"

# Render smoke for the cdp-ramp card: the page it mounts on ships
# shared/_alpine_factories, so cdpRampFlow — inline-only, with no importmap
# duplicate — exists wherever the card can open.
#
# WAS TWO SMOKES, THEN DROVE A PREVIEW. The sibling asserted /admin/modals
# LISTED the "CDP ramp (Coinbase)" variant group and went with the gallery on
# 2026-09-09. This one drove /admin/modals/preview/cdp-ramp until that seam was
# retired too, and it now asks the identical question of layouts/application —
# the layout that actually renders this card to a player, rather than a second
# layout keeping a second registration list.
#
# THE FLAG IS A PRECONDITION, NOT A DETAIL. layouts/application registers this
# card behind cdp_ramp_modal_available? (logged in AND ENABLE_CDP_RAMP), and the
# flag is off by default in dev, test and QA. Without both arranged the page
# carries NO cdp-ramp registration, and an assertion against the whole body
# would then be answering a question about the rest of the page. The
# registration is counted first for that reason.
class CdpPreviewSmokeTest < ActionDispatch::IntegrationTest
  setup do
    @cdp_ramp_flag = ENV["ENABLE_CDP_RAMP"]
    ENV["ENABLE_CDP_RAMP"] = "true"
  end

  teardown do
    if @cdp_ramp_flag.nil?
      ENV.delete("ENABLE_CDP_RAMP")
    else
      ENV["ENABLE_CDP_RAMP"] = @cdp_ramp_flag
    end
  end

  test "the cdp-ramp card renders on the app layout with the factory inline" do
    log_in_as users(:alex)
    body = modal_host_page

    cards = modal_registration_sources(body, "cdp-ramp")
    assert_equal 1, cards.length,
                 "expected exactly one cdp-ramp registration on the app layout; found " \
                 "#{cards.length}. Zero means the flag or the login did not take and every " \
                 "assertion below is vacuous; two is a duplicate registration free to drift."

    assert_includes body, "window.cdpRampFlow",
                    "the page registers the card but never defines its factory, so the modal " \
                    "mounts as a silent Alpine no-op"
    assert_includes cards.first, "Send your USDC to Coinbase",
                    "the card's send step is missing from the rendered arm set"
  end
end
