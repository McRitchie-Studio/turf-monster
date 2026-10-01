# GET /api/v1/entries/:slug, and the MCP tool `get_entry`: one of the caller's
# own confirmed entries. Another player's slug is RecordNotFound, the same
# answer as a slug that does not exist.
module Api
  module V1
    module Operations
      class GetEntry < Base
        def call
          ok(entry: serialize_entries([find_entry]).first)
        end
      end
    end
  end
end
