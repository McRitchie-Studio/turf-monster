# The account freeze (OPSEC-048), DEFAULT-DENY, for every controller that can
# write: the web (ApplicationController, and every engine controller that
# inherits it) and the agent API (ApiKeyAuthentication, so /api/v1 and /mcp).
#
# A frozen account keeps its READS — browsing contests, its own entries,
# signing in and out — and loses every WRITE: entering, editing an entry, chat,
# a username change, linking a wallet, every on-chain step, buying, depositing,
# withdrawing and profile edits. The rule is "every request that is not a GET or
# a HEAD", so a write path is covered the day it is routed, with nothing to
# remember. One answer everywhere:
#
#   code     account_frozen
#   status   403
#   message  FrozenAccount::MESSAGE
#
# The web answers an HTML form post with a 303 back and the message as an
# alert, and everything else (fetch, XHR, JSON) with
# `{ "error": <message>, "code": "account_frozen" }`. The API host answers in
# its own envelope (`render_frozen_account_refusal`).
#
# OPTING OUT is by name, with a reason, and is the only way:
#
#   allow_frozen_account_writes only: :destroy, reason: "revoking a key removes access"
#
# A bare call, an empty `only:`, or a blank reason does not load. The reasons
# are data (`frozen_write_exemptions`), and test/integration/frozen_account_
# write_inventory_test.rb walks every routed write and holds each one to this
# gate or to a named exemption. An exempt action that writes owes the check
# itself (`current_user.frozen?`, or the API's `frozen_account_refusal`).
#
# The model layer repeats the rule where a write lands (FrozenAccount::
# Validation on Entry, Selection, Message, Reaction and User), so a path that
# never passes through a controller — a job, a console, a future surface —
# still cannot write for a frozen user.
module FrozenAccountGuard
  extend ActiveSupport::Concern

  included do
    class_attribute :frozen_write_exemptions, instance_writer: false, default: {}.freeze
    before_action :refuse_frozen_account_writes
  end

  class_methods do
    def allow_frozen_account_writes(only:, reason:)
      actions = Array(only).map(&:to_sym)
      raise ArgumentError, "allow_frozen_account_writes needs only: with at least one action" if actions.empty?
      raise ArgumentError, "allow_frozen_account_writes needs a reason:" if reason.to_s.strip.empty?

      self.frozen_write_exemptions = frozen_write_exemptions.merge(actions.index_with { reason.to_s }).freeze
    end

    def frozen_write_exempt?(action)
      frozen_write_exemptions.key?(action.to_sym)
    end
  end

  private

  # Would this request be refused for the account freeze? A plain question,
  # rendering nothing. (Private: a public method on a controller is an action.)
  def frozen_account_write_blocked?
    return false if request.get? || request.head?
    return false if self.class.frozen_write_exempt?(action_name)

    current_user&.frozen? || false
  end

  def refuse_frozen_account_writes
    render_frozen_account_refusal if frozen_account_write_blocked?
  end

  # The web's answer. ApiKeyAuthentication overrides it with its own envelope.
  def render_frozen_account_refusal
    if frozen_refusal_wants_html?
      redirect_back_or_to account_path, alert: FrozenAccount::MESSAGE, status: :see_other
    else
      render json: { error: FrozenAccount::MESSAGE, code: FrozenAccount::CODE }, status: FrozenAccount::STATUS
    end
  end

  # A browser form post (plain or Turbo) asks for text/html; a fetch() from the
  # page's own JS sends */* or JSON and reads `error` from a JSON body.
  def frozen_refusal_wants_html?
    return false if request.xhr?
    return false if request.content_mime_type&.json?

    request.headers["Accept"].to_s.include?("text/html")
  end
end
