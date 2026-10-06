require "test_helper"

# [unit] ApiKeyAuthentication on a controller that is NOT part of the shipped
# API — the behaviours GET /api/v1/me cannot show because it is read-only and
# does not fail: the write gates (the account freeze, refused by default on
# every non-read; the age re-check a write asks for) and the envelope an
# unexpected error is answered in.
#
# No shipped endpoint writes yet, so the probe is the only place the gates run.
# It has one action of each kind a real surface will have: a plain write, a
# read, a write that also re-asks the age gate, and a single POST action that
# dispatches several "tools" and asks the plain questions itself — the shape
# the MCP endpoint will take.
class ApiKeyAuthenticationTest < ActionDispatch::IntegrationTest
  class ProbeController < Api::V1::BaseController
    allow_frozen_account_writes only: :dispatch_tool, reason: "test double: asks write_refusal per tool"
    before_action :require_age_verified, only: :enter

    cattr_accessor :reraise, default: false

    def spend
      render json: { spent: true }
    end

    def read
      render json: { read: true }
    end

    def enter
      render json: { entered: true }
    end

    # One action, many operations, its own envelope: nothing here may render
    # the REST error shape, so it asks the questions and words the answer.
    def dispatch_tool
      refusal = params[:tool] == "write" ? write_refusal : nil
      return render json: { tool_error: refusal.code, text: refusal.message } if refusal

      render json: { tool: params[:tool], ok: true }
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
    @key = ApiKey.mint!(user: @user, name: "Claude", geo_country: "US", geo_state: "CO", age_result: "not_required")
  end

  # with_routing restores the real routes — and drops the response — when its
  # block returns, so the status and body are captured inside it.
  def probe(action, verb: :post, params: {}, authorization: "Bearer #{@key.raw_token}")
    with_routing do |set|
      set.draw do
        controller = "api_key_authentication_test/probe"
        match "probe/spend", to: "#{controller}#spend", via: %i[post put patch delete]
        match "probe/read", to: "#{controller}#read", via: %i[get head]
        post "probe/enter", to: "#{controller}#enter"
        post "probe/dispatch_tool", to: "#{controller}#dispatch_tool"
        post "probe/boom", to: "#{controller}#boom"
        post "probe/missing", to: "#{controller}#missing"
      end
      send(verb, "/probe/#{action}", params: params,
                                     headers: authorization ? { "Authorization" => authorization } : {})
      @status = response.status
      @body = response.body
    end
  end

  def error
    JSON.parse(@body).fetch("error")
  end

  def with_age_gate(value = "true")
    prior = ENV["ENABLE_AGE_GATE"]
    value.nil? ? ENV.delete("ENABLE_AGE_GATE") : ENV["ENABLE_AGE_GATE"] = value
    yield
  ensure
    prior.nil? ? ENV.delete("ENABLE_AGE_GATE") : ENV["ENABLE_AGE_GATE"] = prior
  end

  def freeze_account
    @user.freeze_for_payment_risk!(reason: "test")
  end

  test "a POST needs no CSRF token" do
    ActionController::Base.stub :allow_forgery_protection, true do
      probe :spend
    end

    assert_equal 200, @status
  end

  # --- the freeze: refused by default on every non-read -------------------------

  test "a frozen account is refused 403 account_frozen on a write that declared nothing" do
    freeze_account

    probe :spend

    assert_equal 403, @status
    assert_equal "account_frozen", error["code"]
    assert_match(/frozen/i, error["message"])
  end

  test "the default covers every writing verb" do
    freeze_account

    %i[post put patch delete].each do |verb|
      probe :spend, verb: verb

      assert_equal 403, @status, "#{verb.upcase} reached a frozen account"
      assert_equal "account_frozen", error["code"]
    end
  end

  test "a frozen account can still read: GET and HEAD pass" do
    freeze_account

    probe :read, verb: :get
    assert_equal 200, @status
    assert_equal({ "read" => true }, JSON.parse(@body))

    probe :read, verb: :head
    assert_equal 200, @status
  end

  test "an unfrozen account passes the gate" do
    probe :spend

    assert_equal 200, @status
    assert_equal({ "spent" => true }, JSON.parse(@body))
  end

  test "a keyless write is a 401, not a freeze verdict" do
    freeze_account

    probe :spend, authorization: nil

    assert_equal 401, @status
    assert_equal "missing_api_key", error["code"]
  end

  # --- the opt-out, and the plain questions it leaves the action to ask ---------

  test "an opted-out action is reachable by a frozen account" do
    freeze_account

    probe :dispatch_tool, params: { tool: "read" }

    assert_equal 200, @status
    assert_equal({ "tool" => "read", "ok" => true }, JSON.parse(@body))
  end

  test "an opted-out action refuses its writing operation itself, in its own envelope" do
    freeze_account

    probe :dispatch_tool, params: { tool: "write" }

    assert_equal 200, @status, "the question must not render the REST error for the caller"
    body = JSON.parse(@body)
    assert_equal "account_frozen", body["tool_error"]
    assert_match(/frozen/i, body["text"])
    assert_not body.key?("error")
  end

  test "the opt-out is per action: the controller's other writes stay gated" do
    freeze_account

    probe :spend

    assert_equal 403, @status
  end

  test "write_refusal asks the age gate too, after the freeze" do
    @user.update_columns(age_attested_at: nil)

    with_age_gate do
      probe :dispatch_tool, params: { tool: "write" }
      assert_equal "age_verification_required", JSON.parse(@body)["tool_error"]

      freeze_account
      probe :dispatch_tool, params: { tool: "write" }
      assert_equal "account_frozen", JSON.parse(@body)["tool_error"]
    end
  end

  test "write_refusal is nil for an account in good standing" do
    @user.update_columns(age_attested_at: Time.current)

    with_age_gate { probe :dispatch_tool, params: { tool: "write" } }

    assert_equal({ "tool" => "write", "ok" => true }, JSON.parse(@body))
  end

  # --- the age re-check ----------------------------------------------------------

  test "with the age gate on, an unverified player is refused 403 age_verification_required" do
    @user.update_columns(age_attested_at: nil)

    with_age_gate { probe :enter }

    assert_equal 403, @status
    assert_equal "age_verification_required", error["code"]
    assert_match(/verify your age/i, error["message"])
  end

  # The case the stamp cannot answer: the key was minted while the gate was off.
  test "a key stamped not_required does not excuse the re-check once the gate is on" do
    @user.update_columns(age_attested_at: nil)
    assert_equal "not_required", @key.eligibility_age_result

    with_age_gate { probe :enter }

    assert_equal 403, @status
  end

  test "with the age gate on, a verified player passes" do
    @user.update_columns(age_attested_at: Time.current)

    with_age_gate { probe :enter }

    assert_equal 200, @status
    assert_equal({ "entered" => true }, JSON.parse(@body))
  end

  test "with the age gate off, an unverified player passes" do
    @user.update_columns(age_attested_at: nil)

    with_age_gate(nil) { probe :enter }

    assert_equal 200, @status
  end

  test "the age re-check is opt-in: a write that did not ask for it is not age-gated" do
    @user.update_columns(age_attested_at: nil)

    with_age_gate { probe :spend }

    assert_equal 200, @status
  end

  test "the shipped read endpoints are untouched by either gate" do
    freeze_account
    @user.update_columns(age_attested_at: nil)

    with_age_gate do
      [api_v1_me_path, api_v1_contests_path, api_v1_entries_path].each do |path|
        get path, headers: { "Authorization" => "Bearer #{@key.raw_token}" }

        assert_response :success, "GET #{path} must stay open to a frozen, unverified player"
      end
    end
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

  # --- the opt-out must name its actions -------------------------------------------

  # A bare opt-out would lift the freeze gate from every action of the
  # controller, present and future. That spelling must not load, and neither
  # may one that does not say why. Each case below passes the OTHER keyword,
  # so the one under test is the one that refuses.
  test "allow_frozen_account_writes refuses to be called without only:" do
    why = "test"
    assert_raises(ArgumentError) { Class.new(Api::V1::BaseController) { allow_frozen_account_writes reason: why } }
    assert_raises(ArgumentError) { Class.new(Api::V1::BaseController) { allow_frozen_account_writes only: [], reason: why } }
    assert_raises(ArgumentError) { Class.new(Api::V1::BaseController) { allow_frozen_account_writes only: nil, reason: why } }
    assert_raises(ArgumentError) { Class.new(Api::V1::BaseController) { allow_frozen_account_writes except: :read, reason: why } }
  end

  test "allow_frozen_account_writes refuses to be called without a reason" do
    assert_raises(ArgumentError) { Class.new(Api::V1::BaseController) { allow_frozen_account_writes only: :create } }
    assert_raises(ArgumentError) { Class.new(Api::V1::BaseController) { allow_frozen_account_writes only: :create, reason: " " } }
    klass = Class.new(Api::V1::BaseController) { allow_frozen_account_writes only: :create, reason: "control" }
    assert klass.frozen_write_exempt?(:create), "a named action with a reason loads and is exempt"
    assert_not klass.frozen_write_exempt?(:update)
    assert_not Api::V1::BaseController.frozen_write_exempt?(:create), "the exemption stays on the subclass"
  end
end
