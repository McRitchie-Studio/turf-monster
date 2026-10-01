# An operation's Outcome as an MCP tool result (CallToolResult).
#
# THE MAPPING TO REST. The JSON is the same JSON: a success is the body the
# REST endpoint returns, a failure is the same `{ "error": { code, message } }`
# envelope with `isError: true`. What REST says with a status line and headers
# travels in `_meta`, for a client that wants it:
#
#   turfmonster.media/http_status          200, 201, 202, 403, 404, 409, 422, 503 …
#   turfmonster.media/retry_after          seconds (REST: Retry-After)
#   turfmonster.media/idempotent_replayed  true    (REST: Idempotent-Replayed)
#
# `structuredContent` exists from revision 2025-06-18. The text block is always
# sent and always the same JSON, serialized: "a tool that returns structured
# content SHOULD also return the serialized JSON in a TextContent block"
# (server/tools, "Structured Content").
#
# TWO ANSWERS A MODEL TENDS TO MISREAD get a second text block saying what to
# do, because the status line that tells a REST client is not something a model
# sees:
#
#   202 pending   not an error. The entry is PAID and still being confirmed.
#   a retry_after an error that is cured by calling again with the same key
#                 (idempotency_in_progress, chain_unavailable).
module AgentMcp
  module ToolResult
    META = "turfmonster.media".freeze

    def self.render(outcome, version:)
      payload = outcome.payload.as_json
      result = { content: [{ type: "text", text: JSON.generate(payload) }] }
      note = guidance(outcome)
      result[:content] << { type: "text", text: note } if note
      result[:structuredContent] = payload if Protocol.structured_content?(version)
      result[:isError] = outcome.error?
      result[:_meta] = meta(outcome)
      result
    end

    def self.meta(outcome)
      {
        "#{META}/http_status" => outcome.http_status,
        "#{META}/retry_after" => outcome.retry_after,
        "#{META}/idempotent_replayed" => outcome.replayed ? true : nil
      }.compact
    end

    def self.guidance(outcome)
      seconds = outcome.retry_after
      if !outcome.error? && outcome.status == :accepted
        "PENDING, NOT A FAILURE. The entry is paid for and is still being confirmed. Call submit_entry again " \
          "in #{seconds} seconds with the SAME idempotency_key and the same arguments to receive the entry. " \
          "Do not use a new idempotency_key, and do not tell the player the entry failed."
      elsif outcome.error? && seconds
        "RETRY. Call the same tool again in #{seconds} seconds with the SAME idempotency_key and the same " \
          "arguments. Do not use a new idempotency_key: the server looks for the first payment before it pays again."
      end
    end
  end
end
