# What an agent API operation answers with, before any surface has rendered it.
#
# `status` is a Rails status symbol and `body` the JSON a success returns. A
# refusal carries `error_code` and `message` instead, and renders as the one
# error envelope (`error_body`). `retry_after` and `replayed` are the two facts
# REST sends as headers (Retry-After, Idempotent-Replayed).
#
# Same fields as Entries::ApiSubmission::Result, which is where the shape came
# from: an entry submission is one operation among eight.
module Api
  module V1
    module Operations
      Outcome = Struct.new(:status, :body, :error_code, :message, :retry_after, :replayed, keyword_init: true) do
        def self.ok(body, status: :ok)
          new(status: status, body: body)
        end

        def self.error(code, message, status:, retry_after: nil)
          new(status: status, error_code: code, message: message, retry_after: retry_after)
        end

        # From ApiKeyAuthentication::Refusal (code, message, status).
        def self.refused(refusal)
          error(refusal.code, refusal.message, status: refusal.status)
        end

        def error? = !error_code.nil?

        def http_status = Rack::Utils.status_code(status)

        # The envelope every agent API error uses (docs/AGENT_API.md, "Errors").
        def error_body
          { error: { code: error_code.to_s, message: message, retry_after: retry_after }.compact }
        end

        def payload = error? ? error_body : body
      end
    end
  end
end
