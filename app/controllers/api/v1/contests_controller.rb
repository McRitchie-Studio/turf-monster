# The contests an agent can read: the list, one contest with its pickable
# teams, and its leaderboard (docs/AGENT_API.md). Read-only, so every action
# answers for a frozen account, as GET /api/v1/me does.
#
# VISIBILITY IS THE WEB'S, and lives in the operations each action names
# (app/services/api/v1/operations):
#   list         open and settled contests, newest first, which is exactly
#                ContestsController#index. A `pending` contest (created, its
#                on-chain broadcast not yet verified) is never listed, to anyone.
#   one contest  ContestsController#set_contest: pending is a 404 unless the
#                key's player is an admin, who needs to open a stranded row.
#   cancelled    still listed and still readable, flagged `cancelled`. It keeps
#                `status: "open"` on the row, so the flag is the only tell.
#   rival picks  hidden until the contest locks (ContestsHelper#picks_visible_for?).
module Api
  module V1
    class ContestsController < BaseController
      def index
        run Operations::ListContests
      end

      def show
        run Operations::GetContest
      end

      def leaderboard
        run Operations::GetLeaderboard
      end
    end
  end
end
