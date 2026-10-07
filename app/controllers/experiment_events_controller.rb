# POST /experiment-events — the beacon a page experiment's page sends
# (page_experiments.js, navigator.sendBeacon): `visit` on first paint, and
# `cta:<name>` when a call to action is tapped.
#
#   params: experiment=<slug>  event=visit|<cta name>  authenticity_token
#
# THE CLIENT NAMES ONLY THE EXPERIMENT AND THE EVENT. The variant is read from
# the visitor's own sticky cookie (exp_<slug>) and the visitor from the
# referral_visitor cookie, so a forged beacon cannot credit a variant the
# visitor was never shown; the event is checked against a closed list
# (ExperimentEvent::EVENTS). CSRF stays on: the token rides in the beacon's
# form body, since sendBeacon cannot set a header.
#
# Always 204, recorded or not: a beacon has no reader, and the answer must not
# tell a script which of its rows landed. Never blocks the tap it reports:
# sendBeacon is fire-and-forget, so the navigation does not wait for this.
class ExperimentEventsController < ApplicationController
  # OPSEC-048: FrozenAccountGuard refuses a frozen account every write but this.
  allow_frozen_account_writes only: :create, reason: "an anonymous A/B beacon; records a page view, acts for no one"

  skip_before_action :require_authentication
  skip_before_action :require_profile_completion
  skip_before_action :preload_navbar_solana_data

  def create
    record_beacon
    head :no_content
  end

  private

  def record_beacon
    return if ReferralVisit.bot?(request.user_agent)

    event = beacon_event
    # Running experiments only: a paused one counts nothing, cookie or not.
    experiment = event && PageExperiment.active.includes(:variants).find_by(slug: params[:experiment].to_s)
    variant = experiment&.variant_for(cookies[experiment.cookie_name])
    return if variant.nil?

    record_experiment_event(experiment.slug, variant.key, event)
  rescue StandardError => e
    ReferralVisit.report_failure(e, "experiment beacon skipped")
  end

  def beacon_event
    name = params[:event].to_s
    name == ExperimentEvent::VISIT ? name : ExperimentEvent.cta_event(name)
  end
end
