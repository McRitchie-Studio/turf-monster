# Skips perform for every parked fiat job (FiatRailsParked::JOBS) while
# AppFlags.fiat_rails? is off, with a WARN log line naming the job. The job is
# acknowledged, not retried: parking assumes no fiat purchase or deposit is in
# flight, which docs/FIAT_RAILS.md makes the precondition for switching off.
module FiatRailsJobGate
  extend ActiveSupport::Concern

  included do
    around_perform :skip_parked_fiat_job
  end

  private

  def skip_parked_fiat_job
    if FiatRailsParked.parked_job?(self) && !AppFlags.fiat_rails?
      Rails.logger.warn("[fiat-parked] skipped #{self.class.name} job_id=#{job_id}: ENABLE_FIAT_RAILS is off (docs/FIAT_RAILS.md)")
      return
    end

    yield
  end
end
