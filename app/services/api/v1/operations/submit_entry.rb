# POST /api/v1/contests/:slug/entries, and the MCP tool `submit_entry`: create
# an entry and pay for it, in one call, at most once per idempotency key.
#
# This class only reads the request. Every rule, the idempotency record, the
# single-flight claim and the fencing before the spend are
# Entries::ApiSubmission's, which both surfaces therefore reach through the
# same door with the same arguments.
#
# The key arrives differently on each surface (REST: the Idempotency-Key
# header; MCP: the `idempotency_key` argument), so the caller passes it in,
# with the words to use when it is missing or malformed.
module Api
  module V1
    module Operations
      class SubmitEntry < Base
        REST_KEY_LABEL = "an Idempotency-Key header".freeze

        def initialize(idempotency_key:, key_label: REST_KEY_LABEL, **rest)
          super(**rest)
          @idempotency_key = idempotency_key
          @key_label = key_label
        end

        def call
          contest = find_contest
          key = checked_idempotency_key
          matchup_ids = id_list_param(:matchup_ids)
          allow_usdc = boolean_param(:allow_usdc)

          result = Entries::ApiSubmission.new(
            user: user, api_key: api_key, contest: contest,
            matchup_ids: matchup_ids, allow_usdc: allow_usdc, idempotency_key: key,
            serializer: ->(entry) { serialize_entries([load_entry(entry.id)]).first }
          ).call

          Outcome.new(status: result.status, body: result.body, error_code: result.error_code,
                      message: result.message, retry_after: result.retry_after, replayed: result.replayed)
        end

        private

        def checked_idempotency_key
          key = @idempotency_key
          bad_request!("Send #{@key_label}: a unique value for this entry, repeated on every retry.") if key.blank?
          unless key.is_a?(String) && key.match?(ApiEntryRequest::KEY_FORMAT)
            bad_request!("Idempotency-Key must be 1 to 255 printable characters with no spaces.")
          end
          key
        end
      end
    end
  end
end
