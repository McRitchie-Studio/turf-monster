require "test_helper"
require "minitest/mock"

# Lazarus audit #2 (2026-05-31): the wallet-export reveal page renders a
# decrypted private key into the DOM. It must never load third-party session
# replay (LogRocket), must redact the key elements, and must not be cached or
# leak a referrer.
class WalletExportsShowTest < ActionDispatch::IntegrationTest
  setup do
    @managed = User.create!(
      name: "Sienna Secret", username: "sienna-secret-#{SecureRandom.hex(2)}",
      email: "secret-#{SecureRandom.hex(2)}@example.test",
      email_verified_at: Time.current
    )
    grant_managed_wallet!(@managed)
    assert @managed.reload.managed_wallet?, "the export page needs a custodial wallet to reveal"

    # Pin export_initiated_at and mint the token the magic email would have
    # carried — same shape as AccountsController#initiate_wallet_export.
    @managed.update!(export_initiated_at: Time.current)
    @token = Rails.application.message_verifier("wallet_export_v1").generate(
      { user_id: @managed.id, email: @managed.email, initiated_at: @managed.export_initiated_at.to_i },
      expires_in: 30.minutes
    )
  end

  test "reveal page renders the wallet but never loads third-party session replay" do
    get wallet_export_path(token: @token)
    assert_response :success
    # The page must still work — the user needs to see/copy their key.
    assert_includes response.body, @managed.solana_address
    # ...but a page holding a private key must not ship it to LogRocket.
    assert_no_match %r{logr-in\.com}, response.body, "LogRocket must not load on the key-reveal page"
    assert_no_match(/LogRocket\.identify/, response.body)
  end

  # The control the test above cannot be: outside production nobody loads
  # replay, so its absence there proves nothing. Signed in, with the replay
  # environment answered as production, the layout would load LogRocket on any
  # other page (session_replay_layout_test.rb); the reveal page still does not.
  test "a signed-in owner in production still loads no session replay on the reveal page" do
    log_in_as(@managed)
    ApplicationHelper.stub(:session_replay_environment?, true) do
      get wallet_export_path(token: @token)
    end
    assert_response :success
    assert_not response.body.include?("logr-in.com"), "LogRocket must not load on the key-reveal page"
    assert_not response.body.include?("LogRocket.identify"), "LogRocket.identify must not render on the key-reveal page"
  end

  test "secret-key blocks are marked data-private for replay redaction" do
    get wallet_export_path(token: @token)
    assert_response :success
    assert_includes response.body, "data-private",
      "secret key elements must carry data-private as defense-in-depth"
  end

  test "reveal page is uncacheable and leaks no referrer" do
    get wallet_export_path(token: @token)
    assert_response :success
    assert_match(/no-store/, response.headers["Cache-Control"].to_s)
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
  end
end
