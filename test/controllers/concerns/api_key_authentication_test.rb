require "test_helper"

# [integration] ApiKeyAuthentication on a controller that is NOT part of the
# shipped API — the two behaviours GET /api/v1/me cannot show because it is
# read-only and does not fail: the account-freeze gate that write endpoints
# hang on, and the envelope an unexpected error is answered in.
class ApiKeyAuthenticationTest < ActionDispatch::IntegrationTest
  class ProbeController < Api::V1::BaseController
    before_action :require_unfrozen_account, only: :spend

    cattr_accessor :reraise, default: false

    def spend
      render json: { spent: true }
    end

    def boom
      raise "kaboom with internals"
    end

    def missing
      User.find(-1)
    end

    private

    def reraise_unexpected_api_errors?
      self.class.reraise
    end
  end

  setup do
    @user = users(:jordan)
    @key = ApiKey.mint!(user: @user, geo_country: "US", geo_state: "CO", age_result: "not_required")
  end

  # with_routing restores the real routes — and drops the response — when its
  # block returns, so the status and body are captured inside it.
  def probe(action, authorization: "Bearer #{@key.raw_token}")
    with_routing do |set|
      set.draw do
        post "probe/spend", to: "api_key_authentication_test/probe#spend"
        post "probe/boom", to: "api_key_authentication_test/probe#boom"
        post "probe/missing", to: "api_key_authentication_test/probe#missing"
      end
      post "/probe/#{action}", headers: authorization ? { "Authorization" => authorization } : {}
      @status = response.status
      @body = response.body
    end
  end

  def error
    JSON.parse(@body).fetch("error")
  end

  test "a POST needs no CSRF token" do
    ActionController::Base.stub :allow_forgery_protection, true do
      probe :spend
    end

    assert_equal 200, @status
  end

  test "a frozen account is refused 403 account_frozen on a gated action" do
    @user.freeze_for_payment_risk!(reason: "test")

    probe :spend

    assert_equal 403, @status
    assert_equal "account_frozen", error["code"]
    assert_match(/on hold/i, error["message"])
  end

  test "an unfrozen account passes the gate" do
    probe :spend

    assert_equal 200, @status
    assert_equal({ "spent" => true }, JSON.parse(@body))
  end

  test "the gate still requires a key" do
    probe :spend, authorization: nil

    assert_equal 401, @status
    assert_equal "missing_api_key", error["code"]
  end

  test "an unexpected error is a 500 envelope that hides the message and writes an ErrorLog for the user" do
    assert_difference -> { ErrorLog.count }, 1 do
      probe :boom
    end

    assert_equal 500, @status
    assert_equal "internal_error", error["code"]
    assert_not_includes @body, "kaboom"
    assert_equal @user, ErrorLog.order(:id).last.target
  end

  test "a missing record is a 404 envelope and no ErrorLog" do
    assert_no_difference -> { ErrorLog.count } do
      probe :missing
    end

    assert_equal 404, @status
    assert_equal "not_found", error["code"]
  end

  test "development and test re-raise an unexpected error by default" do
    ProbeController.reraise = true

    assert_raises(RuntimeError) { probe :boom }
  ensure
    ProbeController.reraise = false
  end
end
