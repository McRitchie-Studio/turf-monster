module Studio
  # Carries one finished game to the hub, off the scoring cycle's thread.
  #
  # Enqueued by `Nfl::LiveScores::PollCycle#finalise`. It is a JOB rather than
  # an inline call for one reason: the poll cycle is the sole path by which
  # production contests re-score, and an HTTP round trip to another host has no
  # business sitting inside that loop. Enqueuing is a Redis write; the worker
  # dyno pays the network cost.
  #
  # Retries come from ApplicationJob (3 attempts, polynomial backoff). The hub
  # endpoint is idempotent, so a retry that actually succeeded the first time
  # answers 200 and changes nothing.
  class GameRecapPushJob < ApplicationJob
    queue_as :default

    def perform(game_slug)
      game = Game.find_by(slug: game_slug)
      return unless game
      return unless Studio::PushGameRecap.configured?

      Studio::PushGameRecap.new(game).call
    end
  end
end
