# A cache store that behaves as production's does while Redis is down.
#
# Production's Rails.cache (and so Rack::Attack.cache) is a RedisCacheStore whose
# error_handler logs and SWALLOWS every connection error
# (config/environments/production.rb). A store that raises is not that: under an
# outage production's store never raises, it answers nil/false. This is the real
# store class, pointed at an address where nothing listens, with an error_handler
# of the same shape that records what it swallowed so a test can prove the
# outage happened rather than assume it.
module RedisCacheOutage
  # Port 1 (tcpmux) is reserved and unserved: connecting is refused at once.
  UNREACHABLE_URL = "redis://127.0.0.1:1/0".freeze

  def self.store(swallowed = [])
    ActiveSupport::Cache::RedisCacheStore.new(
      url: UNREACHABLE_URL,
      namespace: "tm-cache-outage-test",
      connect_timeout: 0.2,
      reconnect_attempts: 0,
      error_handler: ->(method:, returning:, exception:) { swallowed << [method, exception] }
    )
  end

  # Runs the block with rack-attack enabled on an outage store. Yields the list
  # of errors the store swallowed.
  def self.with_rack_attack
    swallowed = []
    prior_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = store(swallowed)
    Rack::Attack.enabled = true
    yield swallowed
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.cache.store = prior_store
  end
end
