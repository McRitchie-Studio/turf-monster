# limit/offset paging for the list endpoints (docs/AGENT_API.md).
#
#   ?limit=25&offset=0   ->   "pagination": { "limit", "offset", "total", "has_more" }
#
# A limit above the maximum is clamped rather than refused, and a limit or
# offset that is not a positive number falls back to the default: an agent that
# asks for too much gets a full page and a `has_more` to follow, not an error.
module Api
  module V1
    module Pagination
      DEFAULT_LIMIT = 25
      MAX_LIMIT = 100

      private

      def page_limit
        requested = params[:limit].to_i
        requested.positive? ? [requested, MAX_LIMIT].min : DEFAULT_LIMIT
      end

      def page_offset
        [params[:offset].to_i, 0].max
      end

      def pagination_json(total)
        { limit: page_limit, offset: page_offset, total: total, has_more: page_offset + page_limit < total }
      end
    end
  end
end
