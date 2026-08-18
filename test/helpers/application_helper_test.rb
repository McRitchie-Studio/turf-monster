require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  # Lazarus audit #2: session replay runs only in production AND never on pages
  # that render secrets (controllers set @suppress_session_replay).
  test "session replay is off outside production" do
    @suppress_session_replay = nil
    assert_not session_replay_active?, "replay must not run outside production (test env)"
  end

  test "session replay runs in production by default but is suppressed on secret pages" do
    original_env = Rails.env
    Rails.env = "production"
    begin
      @suppress_session_replay = nil
      assert session_replay_active?, "replay should be active in production by default"

      @suppress_session_replay = true
      assert_not session_replay_active?, "replay must be suppressed when a controller flags a secret page"
    ensure
      Rails.env = original_env
    end
  end
end
