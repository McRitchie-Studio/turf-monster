# /chat: the agent chat's page (docs/AGENT_CHAT.md).
#
# Studio.agent_chat_allowed is the one gate, so the page, the proxy and the
# footer's link cannot disagree. This is not require_admin on purpose: that sets
# the dense 14px admin type, and a chat box under 16px makes iOS zoom on focus.
class AgentChatPagesController < ApplicationController
  before_action :require_authentication
  before_action :require_chat_allowed

  def show; end

  private

  def require_chat_allowed
    redirect_to root_path, alert: "Not authorized" unless Studio.agent_chat_allowed?(current_user)
  end
end
