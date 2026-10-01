# GET /api/v1/entries, and the MCP tool `list_my_entries`: the caller's own
# confirmed entries (`active` and `complete`), newest first, optionally for one
# contest. A `cart` or `abandoned` entry is never served.
module Api
  module V1
    module Operations
      class ListEntries < Base
        def call
          scope = user.entries.confirmed
          if params[:contest].present?
            contest = Contest.where.not(status: :pending).find_by!(slug: slug_param(:contest))
            scope = scope.where(contest_id: contest.id)
          end

          entries = scope.includes(:selections, contest: :slate)
                         .order(created_at: :desc, id: :desc)
                         .limit(page_limit).offset(page_offset).to_a

          ok(entries: serialize_entries(entries), pagination: pagination_json(scope.count))
        end
      end
    end
  end
end
