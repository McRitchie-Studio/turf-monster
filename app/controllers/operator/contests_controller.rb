module Operator
  # The hub's operator endpoint for contests (Operator::ContestOps), the
  # server-to-server path McRitchie Studio's Turf agent uses to read contests
  # and run an operation the owner confirmed with `go` in a Slack or Discord
  # thread. docs/OPERATOR_API.md.
  #
  #   GET  /_operator/contests                 list (scope open|all, limit 1-25)
  #   POST /_operator/contests/:slug/cancel    queue a cancel for a Treasury cosign
  #   POST /_operator/contests/prepare         a pre-filled /contests/new link
  #
  # INERT BY DEFAULT, as the engine's /_studio/health_report: with no
  # TURF_OPERATOR_TOKEN every request is a bare 404. With one, a request
  # without `Authorization: Bearer <token>` is 401, compared in constant time.
  # The token is its own, never the health report's: that one is read-only.
  #
  # ActionController::API, not ApplicationController: no session, no cookie, no
  # CSRF, none of the host's sign-in, geo or browser gates. Every answer is
  # JSON. A refusal is 422 with a stable `code`; an unexpected error is logged
  # (ErrorLog) and answered 500 with no message.
  class ContestsController < ActionController::API
    TOKEN_ENV = "TURF_OPERATOR_TOKEN".freeze

    before_action :authenticate!

    def index
      render json: { "schema" => 1, "contests" => ops.list(scope: params[:scope], limit: params[:limit] || 10) }
    end

    def cancel
      render json: ops.cancel(slug: params[:slug], paid_entries: params[:paid_entries],
                              requested_by: params[:requested_by], request_ref: params[:request_ref])
                      .merge("schema" => 1)
    end

    def prepare
      render json: ops.prepare(week: params[:week], weeks: params[:weeks] || 1, season: params[:season] || "regular",
                               contest_type: params[:contest_type] || "medium").merge("schema" => 1)
    end

    # Declared first: Rails tries handlers last-declared first, so Refused wins.
    rescue_from StandardError do |e|
      begin
        ErrorLog.capture!(e)
      rescue StandardError
        Rails.logger.warn("[operator] could not write ErrorLog: #{e.class}")
      end
      render json: { "schema" => 1, "error" => "failed" }, status: :internal_server_error
    end

    rescue_from Operator::ContestOps::Refused do |e|
      render json: { "schema" => 1, "error" => e.code, "message" => e.message }, status: :unprocessable_entity
    end

    private

    def ops = Operator::ContestOps.new

    def authenticate!
      response.headers["Cache-Control"] = "no-store"
      token = ENV[TOKEN_ENV].to_s
      return head(:not_found) if token.strip.empty?

      presented = request.authorization.to_s[/\ABearer (.+)\z/, 1].to_s
      return if presented.present? && ActiveSupport::SecurityUtils.secure_compare(presented, token)

      response.headers["WWW-Authenticate"] = 'Bearer realm="turf-operator"'
      render json: { "error" => "unauthorized" }, status: :unauthorized
    end
  end
end
