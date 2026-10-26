# frozen_string_literal: true

# GearSidebarPanels: the DOM ids of the gear sidebar's two panels, in one place.
#
# The gear sidebar (components/_gear_sidebar) renders the same menu twice, a
# desktop panel and a phone panel, and every control that opens it names both
# in aria-controls: the account button the engine draws from
# Studio.navbar_account_sidebar (config/initializers/studio.rb), the gear
# trigger (components/_gear_sidebar_trigger), the free-entry badge
# (components/_entry_token_badge), and the capture-phase click bridge in
# layouts/application, which finds the panels and their close buttons by these
# ids. They were string literals in all of those, so a rename in one left the
# others pointing at nothing, and nothing failed: a dead aria-controls is valid
# markup.
#
# Why they are not the engine's link sidebar ids. studio/link_sidebar claims a
# click on any trigger whose aria-controls names studio-link-sidebar or
# studio-link-sidebar-mobile, so naming either here would open the engine's
# panel instead of this one. studio-engine 0.114.0 refuses them in
# navbar_account_sidebar's controls at assignment;
# test/lib/gear_sidebar_panels_test.rb holds these ids apart from the engine's
# own list (link_sidebar.js LINK_SIDEBAR_PANELS) as well.
#
# Required, not autoloaded: config/initializers/studio.rb reads it at boot, so
# it is on the autoload_lib ignore list in config/application.rb.
module GearSidebarPanels
  DESKTOP = "gear-sidebar"
  MOBILE = "gear-sidebar-mobile"
  IDS = [DESKTOP, MOBILE].freeze
  # The aria-controls value every trigger carries: both panels, space-separated.
  CONTROLS = IDS.join(" ").freeze
end
