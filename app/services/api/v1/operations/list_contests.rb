# GET /api/v1/contests, and the MCP tool `list_contests`: open and settled
# contests, newest first, which is exactly ContestsController#index. A `pending`
# contest (created, its on-chain broadcast not yet verified) is never listed,
# to anyone. A cancelled one is still listed, flagged `cancelled`.
module Api
  module V1
    module Operations
      class ListContests < Base
        LISTED_STATUSES = %w[open settled].freeze
        # The API's `settled` is "graded: ranks and prizes are final" (the
        # guide's lifecycle table), which is two statuses here: a contest is
        # settlement_pending from grading until its payout confirms on chain.
        STATUS_ROWS = { "open" => %w[open], "settled" => Contest::Settlement::GRADED_STATUSES }.freeze

        def call
          scope = Contest.where(status: listed_statuses.flat_map { |status| STATUS_ROWS.fetch(status) })
          contests = scope.includes(:slate).order(created_at: :desc, id: :desc)
                          .limit(page_limit).offset(page_offset).to_a

          ok(contests: serialize_contests(contests), pagination: pagination_json(scope.count))
        end

        private

        # status=open or status=settled narrows the list. Anything else is a
        # 400, not an empty list: `pending` in particular must not look like a
        # filter that happens to match nothing.
        def listed_statuses
          return LISTED_STATUSES if params[:status].nil? || params[:status] == ""
          return [params[:status]] if LISTED_STATUSES.include?(params[:status])

          bad_request!("status must be one of: #{LISTED_STATUSES.join(', ')}.")
        end
      end
    end
  end
end
