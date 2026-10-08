# Request- and job-scoped context. ActiveSupport::CurrentAttributes auto-resets
# between requests (Rack middleware) and between Sidekiq jobs (ActiveJob middleware).
#
# Read by OutboundRequestLogger.record! to attribute Stripe / Solana RPC calls
# back to the originating StripePurchase + user without threading params through
# every layer.
#
#   - `Current.user`            — set by ApplicationController#set_current_context
#   - `Current.outbound_source` — set by jobs/services that own a domain object
#     (e.g. TokenPurchaseJob sets it to the StripePurchase being processed)
class Current < ActiveSupport::CurrentAttributes
  # `:true_admin` — set by ApplicationController#set_current_context when an admin
  # is impersonating (OPSEC-046). Lets OutboundRequestLogger stamp the REAL actor
  # behind an impersonated Stripe/Solana call (acting_admin_id) for audit.
  attribute :user, :outbound_source, :true_admin

  # Per-request memo for the on-chain VaultState read used by the admin
  # dropdown's "Vault Init" / "Vault State (PAUSED)" badges. Both badges
  # answer questions about the same account; without sharing they fire two
  # serial getAccountInfo RPCs on every admin page render.
  # - `_fetched` lets us memoize a legitimate `nil` (vault not yet
  #   initialized) without re-fetching.
  # - `_error` distinguishes "fetched and confirmed nil" (truly
  #   uninitialized) from "RPC failed, we don't know" — vault_uninitialized?
  #   fails safe to `false` in the latter case so a transient RPC blip
  #   doesn't pop the alarming "Vault Init" navbar badge.
  attribute :vault_state, :vault_state_fetched, :vault_state_error

  # Solana::Deadline: the monotonic time this request's or job's Solana RPC
  # waits end, and the LONG_BUDGET name of the block running outside it.
  attribute :rpc_deadline, :rpc_long_budget
end
