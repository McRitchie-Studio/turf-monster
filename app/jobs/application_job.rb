class ApplicationJob < ActiveJob::Base
  retry_on StandardError, wait: :polynomially_longer, attempts: 3
  discard_on ActiveJob::DeserializationError

  # Parked fiat jobs skip while ENABLE_FIAT_RAILS is off (FiatRailsParked::JOBS).
  include FiatRailsJobGate
end
