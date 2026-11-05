require "test_helper"

# [unit] Who may use Turf's agent chat: config/initializers/studio.rb
# (/tasks/turf-chat-takes-voice). This hook is the gate, and it must hold before
# AGENT_CHAT_TOKEN reaches production: the engine's /agent_chat routes skip sign-in.
class AgentChatConfigTest < ActiveSupport::TestCase
  test "only an admin may use the chat" do
    assert Studio.agent_chat_allowed?(users(:alex))
    assert_not Studio.agent_chat_allowed?(users(:jordan))
    assert_not Studio.agent_chat_allowed?(nil)
  end

  test "only an admin may talk, and a signed-out visitor never" do
    assert Studio.voice_chat_allowed?(users(:alex))
    assert_not Studio.voice_chat_allowed?(users(:jordan))
    assert_not Studio.voice_chat_allowed?(nil)
  end

  test "Turf's own soul is the only one on the list, and takes are on" do
    assert_equal %w[turf_monster], Studio.agent_chat_soul_list
    assert Studio.voice_transcription
  end

  test "the voice profile stays off, so this app owes no CSP entries for the embedder" do
    assert_not Studio.voice_profile
  end
end
