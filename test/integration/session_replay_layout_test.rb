require "test_helper"
require "minitest/mock"

# [unit] The layout's LogRocket tags (ApplicationHelper#session_replay_active?):
# in production a signed-out visitor loads no LogRocket at all, and a signed-in
# player loads the recorder, its sanitized init and the slug-only identify.
# The production check (ApplicationHelper.session_replay_environment?, which
# reads Rails.env.production?) is stubbed for the request alone: stubbing
# Rails.env itself sends every production-only boot check in the app off,
# and the page 500s before the layout finishes.
class SessionReplayLayoutTest < ActionDispatch::IntegrationTest
  RECORDER = %r{<script src="https://cdn\.logr-in\.com/LogRocket\.min\.js"}

  def in_production(&block)
    ApplicationHelper.stub(:session_replay_environment?, true, &block)
  end

  test "a signed-out visitor in production loads no LogRocket" do
    in_production { get "/help" }
    assert_response :success
    assert_not response.body.match?(RECORDER), "the LogRocket recorder loads"
    assert_not response.body.match?(/LogRocket\.init/), "LogRocket.init renders"
    assert_not response.body.match?(/LogRocket\.identify/), "LogRocket.identify renders"
  end

  test "a signed-in player in production loads the recorder, the sanitizer and the identify" do
    log_in_as(users(:jordan))
    in_production { get "/help" }
    assert_response :success
    assert response.body.match?(RECORDER), "the LogRocket recorder is missing"
    assert response.body.match?(/LogRocket\.init\('jodsqq\/mcritchie-studio'/), "no LogRocket.init"
    assert response.body.match?(/requestSanitizer/), "no request sanitizer"
    assert response.body.match?(/LogRocket\.identify\('#{users(:jordan).slug}'/), "no slug-only identify"
  end

  test "the production check reads Rails.env" do
    assert_not ApplicationHelper.session_replay_environment?
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("production")) do
      assert ApplicationHelper.session_replay_environment?
    end
  end

  test "outside production nobody loads LogRocket" do
    log_in_as(users(:jordan))
    get "/help"
    assert_response :success
    assert_not response.body.match?(RECORDER), "the LogRocket recorder loads"
  end
end
