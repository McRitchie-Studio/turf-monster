# Any path under /api/ that no route claims (docs/AGENT_API.md, "Errors").
#
# Without this the router's own 404 answered: the HTML error page, to a client
# that parses JSON. It is the last route in the `namespace :api` block, so it
# sees only what nothing else matched, on any verb.
#
# No authentication, on purpose: there is nothing here to protect, and a 401
# would tell a caller with a typo in the path that their key is the problem.
module Api
  module V1
    class ErrorsController < ActionController::API
      def not_found
        render json: { error: { code: "not_found", message: "No such resource." } }, status: :not_found
      end
    end
  end
end
