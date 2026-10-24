module Contests
  # THE COMING-SOON SWEEP (Contest::Reveal). Every tick, for each contest that
  # is coming soon and not held:
  #
  #   1. reveal it, when its reveal_at has passed and it is ready to take money
  #      (open, not cancelled, not locked, on chain, priced);
  #   2. otherwise, if its lock is within a day (or passed while ungraded),
  #      raise ONE alert naming it and its admin URL.
  #
  # A due contest that is not ready is named in the log line with its reason,
  # every run, so "why is this still coming soon" has an answer without a
  # console. Reads no chain and sends nothing: one query, and at most two
  # conditional UPDATEs per contest. A failure on one contest is captured and
  # the rest still run.
  class RevealSweepJob < ApplicationJob
    queue_as :default

    def perform(now: Time.current)
      stats = Hash.new(0)
      waiting = []

      Contest.coming_soon_unheld.includes(:slate).find_each do |contest|
        if contest.reveal!(now)
          stats[:revealed] += 1
          next
        end

        if contest.reveal_due?(now) && (blocker = contest.reveal_blocker)
          waiting << "#{contest.slug}(#{blocker})"
        end
        stats[:alerted] += 1 if contest.alert_coming_soon_at_lock!(now)
      rescue StandardError => e
        stats[:error] += 1
        ErrorLog.capture!(e)
      end

      Rails.logger.info("[contest_reveal][sweep] #{stats.to_h} due_not_ready=#{waiting.size} #{waiting.join(',')}")
      stats
    end
  end
end
