# frozen_string_literal: true

# The class an error_logs row for an OPSEC-045 forced logout is filed under.
#
# It is never raised by a real fault: nothing on the server failed. It is raised
# deliberately, one line deep, so a security event the user only ever met as a
# redirect walks the SAME persistence path as every server-side failure —
# `rescue_and_log` → `ErrorLog.capture!` → target/parent naming → Sentry. See
# ApplicationController#record_session_token_mismatch for why that path is
# entered by a raise rather than by hand, and Solana::ClientWalletFailure for
# the sibling that established the shape.
#
# Its own name is the operator's filter. `ErrorLog.where("inspect LIKE
# '%SessionTokenMismatch%'")` is every forced re-login this app has performed,
# and nothing else — which is what makes "was this user kicked out, or did the
# wallet fetch fail?" a query rather than a guess.
#
# NO TOKEN IN THE MESSAGE. Both halves of the comparison are session
# credentials; the row records only whether the cookie carried one, never its
# value. Same rule as Solana::ClientFailureReport's four-key allowlist.
class SessionTokenMismatch < StandardError; end
