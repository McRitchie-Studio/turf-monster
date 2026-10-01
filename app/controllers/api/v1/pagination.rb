# limit/offset paging for the list endpoints (docs/AGENT_API.md).
#
#   ?limit=25&offset=0   ->   "pagination": { "limit", "offset", "total", "has_more" }
#
# A limit above the maximum is clamped rather than refused: an agent that asks
# for too much gets a full page and a `has_more` to follow. A limit or offset
# that is not a whole number at all (a word, a negative, an array, a number too
# large to be a row count) is a 400, as the doc promises for any invalid
# parameter. It used to fall back to the default, or, for the shapes `to_i`
# does not have, raise a 500.
module Api
  module V1
    module Pagination
      include StrictParams

      DEFAULT_LIMIT = 25
      MAX_LIMIT = 100

      private

      def page_limit
        @page_limit ||= [whole_number_param(:limit, minimum: 1) || DEFAULT_LIMIT, MAX_LIMIT].min
      end

      def page_offset
        @page_offset ||= whole_number_param(:offset, minimum: 0) || 0
      end

      def pagination_json(total)
        { limit: page_limit, offset: page_offset, total: total, has_more: page_offset + page_limit < total }
      end
    end
  end
end
