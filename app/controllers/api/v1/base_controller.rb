# The root of the versioned agent API (docs/AGENT_API.md).
#
# ActionController::API, NOT ApplicationController, and that choice is the
# point: ApplicationController is a browser stack — `allow_browser`, CSRF, the
# cookie session and its token check, geo detection off the request IP, the
# profile-completion redirect, navbar preloads. None of it applies to a bearer
# client and several pieces would refuse one outright. Starting from the API
# base means a new before_action added to ApplicationController can never
# silently start applying here.
#
# Everything this surface needs is in ApiKeyAuthentication.
#
# An action here does no work of its own. It names an operation
# (app/services/api/v1/operations) and renders what comes back; the MCP
# endpoint (McpController) calls the same operations and renders the same
# Outcome as a tool result.
module Api
  module V1
    class BaseController < ActionController::API
      include ApiKeyAuthentication

      private

      def run(operation, **options)
        render_outcome operation.call(user: current_user, api_key: current_api_key, params: params,
                                      writable: write_refusal.nil?, **options)
      end

      # An Outcome as an HTTP response: the body, or the error envelope, at the
      # outcome's status, with the two facts that travel as headers.
      def render_outcome(outcome)
        response.set_header("Retry-After", outcome.retry_after.to_s) if outcome.retry_after
        response.set_header("Idempotent-Replayed", "true") if outcome.replayed
        render json: outcome.payload, status: outcome.status
      end
    end
  end
end
