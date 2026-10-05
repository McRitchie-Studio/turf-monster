# THE TIGHT LOOP: a polling cycle every twenty seconds, but only while there is
# a game to watch.
#
# Nfl::LivePollJob is the floor — every five minutes, all week, on no condition
# at all — and it stays exactly that. Five minutes is fine for "did the week get
# scored"; it is useless for a play-by-play, where the reader is waiting on the
# next snap. Until this job existed the only tighter loop was an agent running
# the `live-score-watch` act by hand, so the board was only ever as live as
# somebody's attention.
#
# WHY THIS ONE MAY BE CONDITIONAL WHEN THE FLOOR MAY NOT. LivePollJob's own note
# refuses a "only poll inside a game window" gate, because the window would be
# derived from the data the job maintains, and a gate like that closes itself
# for good the first time the data is wrong. That argument is about the ONLY
# poller. This is a second one stacked on top: if its gate is wrong it does not
# start, and the cost is the board falling back to five-minute freshness —
# exactly what it had before — while the floor goes on correcting the data the
# gate reads. It cannot make a week disappear.
#
# HOW THE CHAIN RUNS. The floor calls .ensure_running after each of its cycles.
# When a game is in progress or about to kick off, that takes a LEASE (a cache
# key holding a random token) and enqueues the first tick. Each tick runs one
# cycle, renews the lease, and enqueues the next; when nothing is left to watch
# it lets go. Two properties fall out of the token:
#
#   one chain at a time   a second ensure_running finds the lease taken and
#                         does nothing; a tick holding a stale token (its chain
#                         was replaced after a lapse) exits without polling.
#   self-healing          a chain that dies — a deploy, a lost job — simply
#                         stops renewing. The lease expires in ninety seconds
#                         and the floor's next tick starts a fresh one.
#
# THE SWITCH. NFL_LIVE_WATCH=off stops new chains and ends a running one at its
# next tick. NFL_LIVE_WATCH_SECONDS changes the interval.
module Nfl
  class LiveWatchJob < ApplicationJob
    queue_as :default

    LEASE_KEY = "nfl_live_watch:lease".freeze
    DEFAULT_INTERVAL = 20
    # Never tighter than this, whatever the env says. The feed is not ours.
    MIN_INTERVAL = 10
    LEASE_TTL = 90.seconds
    # Start watching this long before a kickoff, so the first snap is not five
    # minutes late.
    LEAD_IN = 10.minutes
    # A game whose kickoff has passed but which the feed has not yet called
    # live is still worth watching — for a while. A postponed game sits in that
    # state for good, and must not hold the loop open all week.
    LATE_START = 4.hours
    # A game stranded at "in_progress" (an unsettled final the week rolled past)
    # never leaves that state by itself, and must not hold the loop open either.
    # Past this it is the floor's to repair, at the floor's pace.
    LIVE_WINDOW = 12.hours

    class << self
      def enabled? = ENV["NFL_LIVE_WATCH"].to_s.downcase != "off"

      def interval
        seconds = ENV["NFL_LIVE_WATCH_SECONDS"].to_i
        seconds = DEFAULT_INTERVAL unless seconds.positive?
        [seconds, MIN_INTERVAL].max.seconds
      end

      # Is there anything to watch? Answered from our own rows, which the
      # five-minute floor keeps current whether or not this loop is running.
      def watching?(now = Time.current)
        games = Game.nfl
        games.where(status: "in_progress", kickoff_at: (now - LIVE_WINDOW)..).exists? ||
          games.where(status: "scheduled", kickoff_at: (now - LATE_START)..(now + LEAD_IN)).exists?
      end

      # Start a chain unless one is running. Safe to call as often as you like.
      def ensure_running
        return false unless enabled? && watching?

        token = SecureRandom.hex(8)
        return false unless Rails.cache.write(LEASE_KEY, token, expires_in: LEASE_TTL, unless_exist: true)

        set(wait: interval).perform_later(token)
        true
      end
    end

    def perform(token)
      # Not our chain any more: the lease lapsed and another took it, or the
      # switch was thrown and it was released.
      return unless Rails.cache.read(LEASE_KEY) == token

      unless self.class.enabled?
        Rails.cache.delete(LEASE_KEY)
        return
      end

      poll

      if self.class.watching?
        Rails.cache.write(LEASE_KEY, token, expires_in: LEASE_TTL)
        self.class.set(wait: self.class.interval).perform_later(token)
      else
        Rails.cache.delete(LEASE_KEY)
      end
    end

    private

    # One cycle. A bad minute at the feed is logged and the chain carries on —
    # the next tick is seconds away, and raising would hand the retry to
    # Sidekiq and break the chain it is trying to keep.
    def poll
      result = LiveScores::PollCycle.call
      result.anomalies.each do |anomaly|
        Rails.logger.warn("[nfl_live_watch][#{anomaly.kind}] #{anomaly.detail}")
      end
    rescue Espn::Client::Error => e
      Rails.logger.warn("[nfl_live_watch] scoreboard unavailable: #{e.message}")
    rescue StandardError => e
      ErrorLog.capture!(e)
    end
  end
end
