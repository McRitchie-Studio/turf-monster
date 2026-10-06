# The parked fiat rails: Stripe, PayPal/Venmo, Coinflow and Aeropay.
#
# The rails return in a later season, so their code stays in the tree, but no
# player, provider or scheduler reaches it unless AppFlags.fiat_rails?
# (ENABLE_FIAT_RAILS) is on. This module is the single list of what is parked;
# docs/FIAT_RAILS.md explains the flag and the checklist to un-park.
#
# How each kind of entry point is gated:
#
#   CONTROLLER_ACTIONS  FiatRailsGate (included at the end of
#                       ApplicationController) answers 404 before any other
#                       callback runs, so a logged-out request and a provider
#                       webhook see the same 404 as a logged-in player.
#   JOBS                FiatRailsGate::Job (included in ApplicationJob) skips
#                       perform with a WARN log line naming the job.
#   VIEWS               Each view is reached only through a parked action or a
#                       predicate that is false while parked (VIEW_GATES).
#
# test/services/fiat_rails_parked_inventory_test.rb discovers fiat files on
# disk and fails when one is missing from these lists.
module FiatRailsParked
  # controller_path => the parked actions, or :all for every action.
  CONTROLLER_ACTIONS = {
    "tokens" => %w[
      stripe_checkout
      paypal_order paypal_capture
      coinflow_order coinflow_simulate_settle
      aeropay_order aeropay_simulate_settle
      processing status
    ].freeze,
    "wallets" => %w[stripe_deposit].freeze,
    "webhooks/stripe" => :all,
    "webhooks/paypal" => :all,
    "webhooks/coinflow" => :all,
    "webhooks/aeropay" => :all
  }.freeze

  # Jobs that move fiat money or mint against it. None has a cron entry except
  # PendingDepositReconcilerJob (config/schedule.yml), which stays scheduled
  # and skips each tick while parked.
  JOBS = %w[TokenPurchaseJob StripeDepositJob PendingDepositReconcilerJob].freeze

  # View path => the predicate that hides it while parked. Each predicate is
  # false whenever AppFlags.fiat_rails? is false, whatever the per-provider
  # switches say; the inventory test measures that.
  #   :parked_action     rendered only by an action in CONTROLLER_ACTIONS
  #   :coinflow          AppFlags.coinflow? or onramp_rail_visible?(:coinflow)
  #   :aeropay           AppFlags.aeropay? or onramp_rail_visible?(:aeropay)
  #   :paypal            Payments.paypal_checkout? (entry_funding_mode :paypal)
  #   :stripe            Payments.stripe? (entry_funding_mode :stripe)
  #   :fiat_rails        an explicit AppFlags.fiat_rails? check in the view
  #   :fiat_callers      rendered only from other views in this list
  #   :fiat_return_poll  the contest board's pollTokenStatus, which fetches the
  #                      parked /tokens/status only after a fiat checkout
  #                      returns, and treats a non-OK answer as not ready
  VIEW_GATES = {
    "app/views/tokens/processing.html.erb" => :parked_action,
    "app/views/tokens/_coinflow_script.html.erb" => :coinflow,
    "app/views/tokens/_aeropay_script.html.erb" => :aeropay,
    "app/views/tokens/_paypal_sdk.html.erb" => :paypal,
    "app/views/tokens/_paypal_buttons.html.erb" => :paypal,
    "app/views/modals/auth/_paypal_tokens.html.erb" => :paypal,
    "app/views/modals/auth/_tokens.html.erb" => :stripe,
    "app/views/tokens/_pack_button.html.erb" => :fiat_callers,
    "app/views/tokens/buy.html.erb" => :fiat_rails,
    "app/views/modals/_wallet_deposit.html.erb" => :fiat_rails,
    "app/views/contests/_turf_totals_board.html.erb" => :fiat_return_poll
  }.freeze

  def self.parked_action?(controller_path, action_name)
    actions = CONTROLLER_ACTIONS[controller_path]
    actions == :all || Array(actions).include?(action_name.to_s)
  end

  def self.parked_job?(job)
    JOBS.include?(job.class.name)
  end
end
