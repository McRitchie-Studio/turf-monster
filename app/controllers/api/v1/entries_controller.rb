# The caller's own entries: the list and one entry (docs/AGENT_API.md).
# Read-only, so it answers for a frozen account.
#
# WHICH ENTRIES. Confirmed ones: `active` (submitted, contest not graded) and
# `complete` (graded). That is Entry.confirmed, the same set the web counts
# toward leaderboards, the per-player limit and "contests I've entered".
#
# A `cart` entry is NOT served, and neither is an `abandoned` one. A cart is the
# website's half-built lineup, saved one tap at a time before the player pays.
# It has no score, no rank and no place on a leaderboard, the API has no way to
# build one (an API entry is submitted whole), and reporting it as an entry
# would tell an agent its player is in a contest they have not entered.
#
# Another player's entry slug is a 404, the same answer as a slug that does not
# exist. Rivals are read through the contest leaderboard, under its own rule.
module Api
  module V1
    class EntriesController < BaseController
      include Pagination

      def index
        scope = current_user.entries.confirmed
        if params[:contest].present?
          contest = Contest.where.not(status: :pending).find_by!(slug: params[:contest])
          scope = scope.where(contest_id: contest.id)
        end

        entries = scope.includes(:selections, contest: :slate)
                       .order(created_at: :desc, id: :desc)
                       .limit(page_limit).offset(page_offset).to_a

        render json: { entries: serialize(entries), pagination: pagination_json(scope.count) }
      end

      def show
        entry = current_user.entries.confirmed
                            .includes(:selections, contest: :slate)
                            .find_by!(slug: params[:slug])

        render json: { entry: serialize([entry]).first }
      end

      private

      # One ContestFacts and one Ranking read for the whole page, and one Board
      # per distinct contest on it.
      def serialize(entries)
        contests = entries.map(&:contest).uniq
        facts = ContestFacts.for(contests)
        ranks = Ranking.for_contests(contests.reject(&:settled?).map(&:id))
        boards = contests.to_h { |contest| [contest.id, Board.new(contest, contest_locked: facts.locked?(contest))] }
        web_rules = WebRules.new(current_user)

        entries.map do |entry|
          EntrySerializer.new(entry, contest: entry.contest, facts: facts, board: boards[entry.contest_id],
                                     ranks: ranks[entry.contest_id], web_rules: web_rules,
                                     viewer: current_user).as_json
        end
      end
    end
  end
end
