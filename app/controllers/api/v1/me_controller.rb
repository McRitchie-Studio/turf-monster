# GET /api/v1/me — who this key acts for, and what they can play with.
#
# The first call an agent makes: it confirms the key works and tells the agent
# whether the player has a free entry to spend and whether the server can sign
# for them. Read-only, so it stays open to a frozen account (and says so).
module Api
  module V1
    class MeController < BaseController
      def show
        run_operation Operations::GetMe
      end
    end
  end
end
