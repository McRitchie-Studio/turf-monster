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

  # --- dollars_short ---
  #
  # The scan-surface money format: `dollars` with the cents dropped when there
  # are none. Each case is paired with what it must NOT do, because "$140" is a
  # substring of "$140.00" and a one-sided assertion here cannot fail.

  test "a whole-dollar amount drops its cents" do
    assert_equal "$140", dollars_short(140.0)
    assert_equal "$19", dollars_short(19)
  end

  test "a fractional amount keeps its cents in full" do
    assert_equal "$19.50", dollars_short(19.5)
    assert_equal "$0.75", dollars_short(0.75)
  end

  test "dollars itself is unchanged — ledgers still get fixed cents" do
    assert_equal "$140.00", dollars(140.0),
      "the ledger format must keep two places; only the short form drops them"
  end

  test "zero is a whole dollar, not a blank" do
    assert_equal "$0", dollars_short(0)
  end
end
