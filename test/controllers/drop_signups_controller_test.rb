require "test_helper"

# [integration] POST /drop-signups — the anonymous "notify me" endpoint.
class DropSignupsControllerTest < ActionDispatch::IntegrationTest
  def post_json(params)
    post drop_signups_path, params: params, headers: { "Accept" => "application/json" }
  end

  test "an anonymous visitor's address is saved under the next slate" do
    assert_difference -> { DropSignup.count }, 1 do
      post_json(email: " Fan@Example.com ", reference: "tiktok")
    end
    assert_response :success
    assert_equal({ "ok" => true }, response.parsed_body)

    row = DropSignup.last
    assert_equal "fan@example.com", row.email
    assert_equal NextSlateDrop::SLATE_KEY, row.slate_key
    assert_equal "tiktok", row.source
    assert_nil row.user
    assert row.ip.present?
  end

  test "the client cannot choose the slate" do
    post_json(email: "fan@example.com", slate_key: "made-up-drop")
    assert_equal NextSlateDrop::SLATE_KEY, DropSignup.last.slate_key
  end

  test "a signed-in visitor's row carries the user" do
    log_in_as(users(:jordan))
    post_json(email: "jordan-drop@example.com")
    assert_response :success
    assert_equal users(:jordan), DropSignup.last.user
  end

  test "a duplicate submit succeeds quietly with no new row and the same answer" do
    post_json(email: "fan@example.com")
    first_body = response.body
    assert_no_difference -> { DropSignup.count } do
      post_json(email: "FAN@example.com")
    end
    assert_response :success
    assert_equal first_body, response.body, "a repeat must be indistinguishable from a first signup"
  end

  test "a malformed address is a 422 with no row" do
    assert_no_difference -> { DropSignup.count } do
      post_json(email: "not-an-email")
    end
    assert_response :unprocessable_entity
    assert_equal false, response.parsed_body["ok"]
    assert_match(/valid email/, response.parsed_body["error"])
  end

  test "the honeypot drops the post silently with the same 200" do
    assert_no_difference -> { DropSignup.count } do
      post_json(email: "bot@example.com", website: "http://spam.example")
    end
    assert_response :success
    assert_equal({ "ok" => true }, response.parsed_body)
  end

  test "a plain form post with a bad address redirects back to the error state" do
    post drop_signups_path, params: { email: "nope" }
    assert_redirected_to turf_monster_v2_path(anchor: "notify")
    follow_redirect!
    assert_select '[data-test="v2-notify-form"] [role="alert"]', text: /valid email/
  end

  # allow_forgery_protection is off in the test env and does not arm inside an
  # integration test (wallet_failure_reporter_wiring_test.rb records that), so
  # this pins the wiring instead: nothing skips the CSRF check on this action.
  test "CSRF verification is not skipped for create" do
    callbacks = DropSignupsController._process_action_callbacks.select { |c| c.kind == :before }
    assert callbacks.any? { |c| c.filter == :verify_authenticity_token },
           "the anonymous write must keep Rails' CSRF check"
  end

  test "the route refuses a .json suffix, so the exact-path throttle cannot be sidestepped" do
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/drop-signups.json", method: :post)
    end
  end
end
