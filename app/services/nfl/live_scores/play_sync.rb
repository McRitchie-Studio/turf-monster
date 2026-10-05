module Nfl
  module LiveScores
    # Writes one game's plays from parsed feed rows, and says which were new.
    #
    # IDEMPOTENT ON ESPN'S PLAY ID, like everything else a cycle writes: handed
    # the same rows twice it writes nothing the second time, so a cycle that
    # dies halfway is repaired by running it again.
    #
    # IT ONLY EVER ADDS AND AMENDS. A play missing from the rows it is handed is
    # left alone, because most calls hand it ONE row — the scoreboard's last
    # play — and "not in this list" then means nothing at all. ESPN does
    # withdraw the odd play after a review; a withdrawn line in a feed nobody
    # is paid on is a smaller harm than a cycle that deletes a game's history
    # because one response was short. (Goals, which ARE paid on, are reconciled
    # in both directions by PollCycle#sync_scoring_plays.)
    #
    # AN AMENDMENT NEVER BLANKS A FIELD. The scoreboard copy of a play has no
    # down and no clock of its own; the summary copy has both. Whichever arrives
    # second must not erase what the first one knew.
    class PlaySync
      def self.call(...) = new(...).call

      # `team_for` is the cycle's memoised abbreviation lookup, handed in so a
      # 190-play backfill does not ask the database for the same two teams 190
      # times.
      #
      # `amend: false` is for the scoreboard's copy of a play, which knows LESS
      # than the summary's: it has no clock or down of its own, and no flag
      # saying a fumble return scored. It may introduce a play; it may not
      # overwrite one the summary has already described.
      def initialize(game:, rows:, team_for:, amend: true)
        @game = game
        @rows = rows
        @team_for = team_for
        @amend = amend
      end

      # Returns the GamePlay rows CREATED by this call, oldest first.
      def call
        return [] if @rows.empty?

        existing = GamePlay.where(external_id: @rows.map(&:external_id)).index_by(&:external_id)

        @rows.filter_map do |row|
          play = existing[row.external_id]
          next create(row) unless play

          amend(play, row) if @amend
          nil
        end.sort_by(&:sequence)
      end

      private

      def create(row)
        GamePlay.create!(
          attributes_for(row).merge(
            game_slug: @game.slug,
            external_id: row.external_id,
            sequence: GamePlay.sequence_for(row.external_id, @game.external_id)
          )
        )
      rescue ActiveRecord::RecordNotUnique
        # Two cycles overlapped (the five-minute floor and the tight loop can)
        # and the other one wrote this play first. It is written; not new to us.
        nil
      end

      def amend(play, row)
        # A play belongs to the game that first reported it. An id turning up
        # under another game is a feed fault, not an amendment.
        return unless play.game_slug == @game.slug

        play.assign_attributes(attributes_for(row).compact)
        play.save! if play.changed?
      end

      def attributes_for(row)
        {
          kind: row.kind, play_type: row.play_type, text: row.text,
          team_slug: @team_for.call(row.team_abbr)&.slug,
          period: row.period, clock: row.clock, down_distance: row.down_distance,
          yards: row.yards, home_score: row.home_score, away_score: row.away_score
        }
      end
    end
  end
end
