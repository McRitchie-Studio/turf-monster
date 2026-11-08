# frozen_string_literal: true

# WHAT TURF'S GLOBAL BEFORE_ACTIONS DO ON THE NOT-FOUND PAGE (task
# turf-adopts-not-found-page; studio-engine docs/NOT_FOUND_PAGE.md).
#
# Studio::NotFoundController inherits ApplicationController, so every global
# callback runs on a 404. The engine throws away any answer that is not a 404
# HTML page and serves public/404.html instead, so a callback can never change
# the status. But it can still cost the page its layout, write to the session or
# the database for an address Turf does not have, or do work a 404 storm should
# never cause. Each callback is decided here, and test/integration/
# not_found_page_test.rb proves each decision.
#
# SKIPPED on the page:
#
#   require_profile_completion   It redirects a signed-in player with an
#                                incomplete profile and stores the address in
#                                session[:return_to]. On a 404 that would send
#                                the player back to a dead address after the
#                                profile step, and the redirect would drop the
#                                page to the static file.
#   preload_navbar_solana_data   The navbar's on-chain warm-up. It is cache-first
#                                today (no RPC), but a 404 storm must never reach
#                                Solana, whatever that method grows into. The
#                                navbar paints its values as "loading" and the
#                                page's own session refresh fills them.
#   track_referral_visit         (ReferralVisitTracking, prepended.) A dead link
#                                with ?r= is not a click on a page, so it writes
#                                no ReferralVisit row. A click PARKED by an
#                                earlier request stays parked (its cookie is not
#                                read or cleared), so the next real page records it.
#   capture_reference            The same reasoning: a dead address seeds no
#                                attribution cookie.
#   detect_geo_state             These two throttle through the session, and the
#   track_user_session (after)   page runs outside the session middleware, so
#                                its session writes are never saved: each 404
#                                would pay an IP lookup or add a UserSession row.
#
# KEPT on the page, on purpose:
#
#   allow_browser                Kept, but the page counts as a public preview
#                                (ApplicationController#public_preview_request?),
#                                so an old browser or a link-preview fetcher gets
#                                the page, not a 406 and the static fallback.
#   verify_session_token         OPSEC-045. A stale session is logged out on any
#                                request, a 404 included. Its sign-in redirect makes
#                                the engine serve public/404.html, still status 404.
#   set_current_context          Request-scoped Current.*; reads only.
#   touch_last_seen              A signed-in player who hits a 404 is active. One
#                                write per five minutes at most; it never raises.
#   refuse_parked_fiat_rail      A no-op here: studio/not_found is no fiat action.
#   refuse_frozen_account_writes A no-op here: the exceptions app always calls the
#                                page as a GET. Kept, never skipped, because it is
#                                the default-deny guard.
#   SigningCsp's after_actions   No-ops here: studio/not_found is no signing page.
#   require_authentication       Turf's override is never a global callback, and
#                                the engine controller skips it (raise: false).
#
# skip_before_action raises at boot if a name above is renamed, so a rename
# cannot silently put a callback back on the page. to_prepare re-applies the
# skips to the fresh class after each code reload in development. Guarded like
# the exceptions_app line in config/application.rb.
Rails.application.config.to_prepare do
  next unless defined?(Studio::NotFoundController)

  Studio::NotFoundController.skip_before_action :require_profile_completion,
                                                :preload_navbar_solana_data,
                                                :track_referral_visit,
                                                :capture_reference,
                                                :detect_geo_state
  Studio::NotFoundController.skip_after_action :track_user_session
end
