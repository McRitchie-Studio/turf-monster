# frozen_string_literal: true

# The two seats this app fills in studio-engine's user nav, passed through
# layouts/_navbar wherever it renders (/tasks/turf-readopts-engine-navbar):
#
#   balance_slot  components/_nav_balance, the wallet amount and its
#                 "✨ Free Entry" face. Passing it also reserves the balance
#                 column (.user-nav-col), signed in and out, as the bar always has.
#   div2_slot     components/_nav_seeds_row, the seeds bar in place of the
#                 engine's wallet-and-level row.
#
# Everything else about the bar is config (config/initializers/studio.rb). The
# live layout and both preview renders (admin/navbar, pages/_laptop_live) call
# this, so a preview draws the same seats as the page.
module NavbarHelper
  NAVBAR_SLOTS = {
    balance_slot: "components/nav_balance",
    div2_slot: "components/nav_seeds_row"
  }.freeze

  def turf_navbar_slots
    NAVBAR_SLOTS
  end
end
