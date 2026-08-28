# frozen_string_literal: true

# THE CARD-WIDTH REGISTRATIONS A PAGE ACTUALLY SHIPS, read as CODE and never as
# prose.
#
# THE TRAP THIS EXISTS FOR, caught by mutation on 2026-08-28. The obvious
# assertion — `response.body =~ /'wallet-setup':\s*'max-w-md'/` — passes on a
# page that registers NOTHING. studio-engine's modal host documents the seam
# with a worked example inside its own inline <script>:
#
#     //   window.StudioModals.CARD_WIDTHS = { 'wallet-setup': 'max-w-md' };
#
# A `//` comment inside an inline script is rendered HTML like any other text,
# so the needle is on every page whether or not this app registers a thing.
# Deleting the registration left the test green.
#
# So match the STATEMENT, anchored at the start of a line on `window.` — which a
# comment line, starting on `//`, cannot satisfy — and read the map out of that.
module RenderedCardWidths
  # An assignment to CARD_WIDTHS, from the start of a line through the first
  # semicolon that ends a line. Spans lines on purpose: a map with more than one
  # entry is written across several.
  STATEMENT = /^[ \t]*window\.StudioModals\.CARD_WIDTHS\s*=.*?;[ \t]*$/m

  module_function

  def statements(body)
    body.scan(STATEMENT)
  end

  # The width registered for one modal id, or nil. Reads every assignment on the
  # page rather than the first, since the app registers and the engine merges.
  def width_for(body, modal_id)
    statements(body).filter_map { |s| s[/'#{Regexp.escape(modal_id)}':\s*'([\w-]+)'/, 1] }.last
  end
end
