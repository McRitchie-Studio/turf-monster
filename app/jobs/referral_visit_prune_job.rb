# Deletes referral_visits rows older than ReferralVisit::RETENTION, nightly
# (config/schedule.yml). Without it the table grows by one row per visitor per
# reference per day for ever. delete_all: the rows have no callbacks and
# nothing points at them.
class ReferralVisitPruneJob < ApplicationJob
  queue_as :default

  def perform
    deleted = ReferralVisit.prune
    Rails.logger.info "[referral_visit_prune] deleted=#{deleted} retention_days=#{ReferralVisit::RETENTION.in_days.to_i}"
  end
end
