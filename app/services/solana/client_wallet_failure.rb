# frozen_string_literal: true

module Solana
  # The class an error_logs row for a CLIENT-SIDE wallet failure is filed under.
  #
  # It is never raised by a real fault: nothing on the server failed. It is
  # raised deliberately, one line deep, so a failure the user only ever saw in
  # the browser walks the SAME persistence path as every server-side one —
  # `rescue_and_log` → `ErrorLog.capture!` → target/parent naming → Sentry. See
  # SolanaSessionsController#record_client_wallet_failure for why that path is
  # entered by a raise rather than by hand.
  #
  # Its own name is the operator's filter. `ErrorLog.where("inspect LIKE
  # '%Solana::ClientWalletFailure%'")` is every wallet failure the browser
  # swallowed, and nothing else.
  class ClientWalletFailure < StandardError; end
end
