# The one page in this app that is allowed to be framed by itself.
#
# WHY IT EXISTS. Chrome puts a newly installed extension into pages loaded
# AFTER the install, and nowhere else. Phantom's provider ships as a
# `document_start` content script (manifest v26.25.0) and its service worker
# runs no install-time sweep over already-open tabs, so a tab that was open
# when the user installed Phantom has no provider in it and never will — no
# amount of polling can find one. That is why the wallet-setup modal used to
# reload the whole page when the user came back from installing.
#
# The same manifest declares `all_frames: true`. So a FRESHLY loaded
# same-origin iframe does get the provider, even inside an old tab. This
# endpoint is that iframe's document: the modal points a hidden frame here
# while it waits, and reads `frame.contentWindow.phantom` across the
# same-origin boundary. Phantom appears, the row flips to Installed in place,
# and the page the user is looking at never moves.
#
# INHERITS ActionController::Base, NOT ApplicationController, on purpose. The
# app's filter chain can redirect (geo state, profile completion, session
# token) and `allow_browser` 406s an old UA — any of which would answer the
# probe with a document that is not this one, and a redirect lands the frame
# on a page whose CSP forbids framing. A probe has to be unconditionally
# itself, so it opts out of all of it.
class WalletProbeController < ActionController::Base
  # The global policy is `frame_ancestors :none` (clickjacking). This page must
  # be frameable by us and only us. Nothing is rendered here worth clickjacking
  # — no data, no controls, no session read — so `:self` costs nothing.
  content_security_policy do |policy|
    policy.frame_ancestors :self
  end

  # Rails' default headers carry X-Frame-Options: SAMEORIGIN, which already
  # permits the same-origin frame; stated here so a future default of DENY
  # cannot silently break detection.
  before_action { response.headers["X-Frame-Options"] = "SAMEORIGIN" }

  # Never cached: every probe must be a NEW document load, because a document
  # served from cache was created before the install and carries no provider.
  before_action do
    response.headers["Cache-Control"] = "no-store, max-age=0"
  end

  def show
    render layout: false
  end
end
