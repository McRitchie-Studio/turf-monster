# Standard competition ranking over a contest's confirmed entries: tied scores
# share a rank and the next rank skips (1, 1, 3).
#
# This is the tie rule Contest#grade! applies when it settles a contest. The API
# uses it for the PROVISIONAL rank of a contest that has not settled yet, so the
# rank an agent watches during the games is the rank grading would hand out if
# the contest ended on those scores. Once a contest settles nothing here is
# consulted: the stored entries.rank is the answer.
#
# (The web leaderboard prints row position, 1..n, until the contest settles, so
# two tied entries read as 1 and 2 there and as 1 and 1 here.)
#
# Order matters and is grade!'s: score descending, then id ascending.
# test/serializers/api/v1/ranking_test.rb grades a tied contest and asserts the
# ranks stored by grade! equal the ranks computed here.
module Api
  module V1
    class Ranking
      # rows: [[entry_id, score], ...] in any order.
      # Returns { entry_id => rank }, with keys in leaderboard order.
      def self.for(rows)
        ordered = rows.sort_by { |id, score| [-score.to_f, id] }
        ranks = {}
        previous_score = nil
        previous_rank = nil

        ordered.each_with_index do |(id, score), index|
          rank = previous_score && score.to_f >= previous_score ? previous_rank : index + 1
          ranks[id] = rank
          previous_score = score.to_f
          previous_rank = rank
        end

        ranks
      end

      # { contest_id => { entry_id => rank } } for many contests in one query.
      def self.for_contests(contest_ids)
        return {} if contest_ids.empty?

        Entry.confirmed.where(contest_id: contest_ids).pluck(:contest_id, :id, :score)
             .group_by(&:first)
             .transform_values { |rows| self.for(rows.map { |_contest_id, id, score| [id, score] }) }
      end
    end
  end
end
