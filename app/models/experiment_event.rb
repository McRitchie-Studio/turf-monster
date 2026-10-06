# One counted moment in a PageExperiment: a visitor seeing a variant (`visit`)
# or tapping one of its calls to action (`cta:<name>`), once per visitor per
# variant per event per day. It is ReferralVisit's dedupe, for the same reason:
# a refresh or a second tap is not a second person.
#
# WHY ITS OWN TABLE AND NOT A COLUMN ON referral_visits. A referral visit
# exists only when a link carried a reference, and the experiment has to count
# every visitor to its page, the organic ones too; and the referral row's
# unique key (reference, visitor, day) would fold a visit and a tap into one.
# The reference a visitor carried is kept here, so the report can still say
# which link brought the hits.
#
# The event names are a closed list (EVENTS): the CTA beacon is a public
# endpoint, and an open list would let anyone mint rows.
#
# NEVER BREAKS A PAGE: .record rescues, reports (ReferralVisit.report_failure)
# and answers false, exactly as ReferralVisit.record does.
class ExperimentEvent < ApplicationRecord
  VISIT = "visit".freeze
  # The page's calls to action, by the name its data-cta attribute carries.
  CTAS = {
    "play" => "Play Turf Monster",
    "notify" => "Notify me",
    "watch_live" => "Watch updates live"
  }.freeze
  EVENTS = ([VISIT] + CTAS.keys.map { |name| "cta:#{name}" }).freeze
  RETENTION = ReferralVisit::RETENTION

  scope :since, ->(date) { date ? where(occurred_on: date..) : all }

  def self.cta_event(name)
    event = "cta:#{name}"
    EVENTS.include?(event) ? event : nil
  end

  # Records one event. true when the call reached the database (a duplicate
  # included: it is already counted), false when there was nothing to record
  # or the write failed.
  def self.record(experiment_slug:, variant_key:, event:, visitor_id:, reference: nil, at: Time.current)
    return false unless EVENTS.include?(event.to_s)
    return false if experiment_slug.blank? || variant_key.blank? || visitor_id.blank?

    insert(
      {
        experiment_slug: experiment_slug.to_s.first(PageExperiment::SLUG_LIMIT),
        variant_key: variant_key.to_s.first(PageVariant::KEY_LIMIT),
        event: event.to_s,
        visitor_id: visitor_id.to_s.first(36),
        occurred_on: at.to_date,
        reference: ReferralVisit.normalize_reference(reference),
        first_seen_at: at
      },
      unique_by: :index_experiment_events_dedupe
    )
    true
  rescue StandardError => e
    ReferralVisit.report_failure(e, "experiment event not recorded exp=#{experiment_slug.inspect} event=#{event.inspect}")
    false
  end

  # Deletes every row older than RETENTION. Returns the count.
  def self.prune(today: Date.current)
    where(occurred_on: ...(today - RETENTION)).delete_all
  end
end
