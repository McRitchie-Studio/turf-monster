require "test_helper"

# [unit] FrozenAccountGuard on the WEB host (ApplicationController), on a probe
# controller that is not part of the app, so the rule is seen with nothing else
# in the way: every non-GET refused for a frozen account, in the shape its
# caller reads; every read open; a named exemption open; and all of it open to
# the same account unfrozen (the control). The API host's copy of the same gate
# is ApiKeyAuthenticationTest.
class FrozenAccountGuardTest < ActionDispatch::IntegrationTest
  class ProbeController < ApplicationController
    allow_frozen_account_writes only: :undo, reason: "probe: an exemption"

    def act
      render json: { acted: true }
    end

    def read
      render json: { read: true }
    end

    def undo
      render json: { undone: true }
    end
  end

  setup do
    @user = users(:jordan)
    log_in_as(@user)
  end

  # with_routing would hand the request a fresh integration session and drop
  # the sign-in, so the probe routes are APPENDED to the real set for the run
  # and the set is reloaded after: the signed-in session and every real route
  # (sign-in, account, the fallback redirect) stay as they are.
  def self.draw_probe_routes!
    Rails.application.routes.disable_clear_and_finalize = true
    Rails.application.routes.draw do
      controller = "frozen_account_guard_test/probe"
      match "__probe/act", to: "#{controller}#act", via: %i[post put patch delete]
      match "__probe/read", to: "#{controller}#read", via: %i[get head]
      post "__probe/undo", to: "#{controller}#undo"
    end
  ensure
    Rails.application.routes.disable_clear_and_finalize = false
  end

  setup { self.class.draw_probe_routes! }
  teardown { Rails.application.reload_routes! }

  def probe(action, verb: :post, headers: {}, as: nil)
    send(verb, "/__probe/#{action}", headers: headers, as: as)
    @status = response.status
    @body = response.body
    @location = response.location
    @alert = flash[:alert]
  end

  def freeze!
    @user.freeze!(reason: "test", source: "console")
  end

  test "a frozen account's write from page JS is a 403 JSON refusal with the code" do
    freeze!
    %i[post put patch delete].each do |verb|
      probe :act, verb: verb, as: :json
      assert_equal 403, @status, verb
      body = JSON.parse(@body)
      assert_equal "account_frozen", body["code"]
      assert_equal FrozenAccount::MESSAGE, body["error"]
    end
  end

  test "a bare fetch (Accept */*) is answered in JSON too" do
    freeze!
    probe :act, headers: { "Accept" => "*/*" }
    assert_equal 403, @status
    assert_equal "account_frozen", JSON.parse(@body)["code"]
  end

  test "a frozen account's browser form post is a 303 back with the message" do
    freeze!
    probe :act, headers: { "Accept" => "text/html,application/xhtml+xml", "Referer" => "http://www.example.com/contests" }
    assert_equal 303, @status
    assert_equal "http://www.example.com/contests", @location
    assert_equal FrozenAccount::MESSAGE, @alert
  end

  test "a frozen account still reads" do
    freeze!
    probe :read, verb: :get
    assert_equal 200, @status
    probe :read, verb: :head
    assert_equal 200, @status
  end

  test "a named exemption stays open to a frozen account" do
    freeze!
    probe :undo
    assert_equal 200, @status
  end

  test "control: the same writes go through for the account unfrozen" do
    %i[post put patch delete].each do |verb|
      probe :act, verb: verb, as: :json
      assert_equal 200, @status, verb
    end
    probe :act, headers: { "Accept" => "text/html" }
    assert_equal 200, @status
  end

  test "control: the freeze lifts the moment the account is unfrozen" do
    freeze!
    probe :act, as: :json
    assert_equal 403, @status

    @user.unfreeze!(reason: "cleared")
    probe :act, as: :json
    assert_equal 200, @status
  end

  test "a signed-out visitor is not the freeze's to refuse" do
    @user.freeze!(reason: "test", source: "console")
    get logout_path
    probe :act, as: :json
    assert_not_equal 403, @status
  end

  test "the opt-out needs only: and a reason" do
    assert_raises(ArgumentError) { Class.new(ApplicationController) { allow_frozen_account_writes reason: "x" } }
    assert_raises(ArgumentError) { Class.new(ApplicationController) { allow_frozen_account_writes only: [], reason: "x" } }
    assert_raises(ArgumentError) { Class.new(ApplicationController) { allow_frozen_account_writes only: :act } }
    assert_raises(ArgumentError) { Class.new(ApplicationController) { allow_frozen_account_writes only: :act, reason: "" } }
    assert_not ApplicationController.frozen_write_exempt?(:undo), "an exemption stays on the class that declares it"
  end
end
