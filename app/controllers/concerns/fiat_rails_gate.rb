# Answers 404 for every parked fiat action (FiatRailsParked::CONTROLLER_ACTIONS)
# while AppFlags.fiat_rails? is off. Included at the end of
# ApplicationController and PREPENDED, so it runs before authentication, CSRF,
# geo and click tracking: a logged-out visitor, a player and a provider webhook
# all get the same 404, and nothing else runs. See docs/FIAT_RAILS.md.
module FiatRailsGate
  extend ActiveSupport::Concern

  included do
    prepend_before_action :refuse_parked_fiat_rail
  end

  private

  def refuse_parked_fiat_rail
    return if AppFlags.fiat_rails?
    return unless FiatRailsParked.parked_action?(controller_path, action_name)

    head :not_found
  end
end
