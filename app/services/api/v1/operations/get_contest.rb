# GET /api/v1/contests/:slug, and the MCP tool `get_contest`: one contest and
# the teams a player may pick.
module Api
  module V1
    module Operations
      class GetContest < Base
        def call
          contest = find_contest
          facts = ContestFacts.for([contest])
          board = Board.new(contest, contest_locked: facts.locked?(contest))

          ok(contest: serialize_contests([contest], facts: facts).first,
             teams: contest.turf_totals? ? board.teams : [])
        end
      end
    end
  end
end
