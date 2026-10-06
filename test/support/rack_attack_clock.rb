# Keeps a Rack::Attack request loop inside one throttle period.
#
# Rack::Attack counts into a bucket named for the wall-clock period it is in
# (Rack::Attack::Cache#key_and_expiry: Time.now.to_i / period). A test whose
# requests straddle a period boundary splits them across two buckets, neither
# reaches the limit, and the 429 it asserts comes back a 200 or a 401. That is a
# flake no local run shows often: a loop spends a second or two in the window,
# so it straddles a minute boundary on a few runs in a hundred, more on slow CI.
#
# in_one_rack_attack_period freezes the clock at the start of the current
# period for the block, so every request in it lands in one bucket. The frozen
# clock is what holds every throttle's bucket fixed, minute and hour alike; the
# start of the period is where it freezes so the travel stays under one period
# and the moment is a whole number of periods. Pass the period of the throttle
# the block asserts on; it defaults to a minute, the shortest one we configure.
#
#   include RackAttackClock
#
#   def with_rack_attack(&block)
#     ...
#     Rack::Attack.enabled = true
#     in_one_rack_attack_period(&block)
#   ensure
#     ...
#   end
module RackAttackClock
  # The start of the period `now` is in, as a time.
  def self.period_start(period, now = Time.now)
    period = period.to_i
    raise ArgumentError, "a throttle period is a positive number of seconds, not #{period.inspect}" unless period.positive?

    Time.zone.at(now.to_i / period * period)
  end

  def in_one_rack_attack_period(period = 1.minute, &block)
    raise ArgumentError, "in_one_rack_attack_period takes a block" unless block

    travel_to(RackAttackClock.period_start(period), &block)
  end
end
