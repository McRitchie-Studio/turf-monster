class ApplicationJob < ActiveJob::Base
  retry_on StandardError, wait: :polynomially_longer, attempts: 3
  discard_on ActiveJob::DeserializationError

  # Parked fiat jobs skip while ENABLE_FIAT_RAILS is off (FiatRailsParked::JOBS).
  include FiatRailsJobGate

  # A Solana::Deadline::LONG_BUDGET name. Set, the job's Solana calls run
  # outside the deadline below.
  class_attribute :rpc_long_budget

  # Each job's Solana calls share Solana::Deadline.job_seconds of waits.
  around_perform do |job, block|
    if job.rpc_long_budget
      Solana::Deadline.long_budget(job.rpc_long_budget, &block)
    else
      Solana::Deadline.within(Solana::Deadline.job_seconds, &block)
    end
  end
end
