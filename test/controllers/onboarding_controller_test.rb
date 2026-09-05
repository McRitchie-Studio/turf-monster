require "test_helper"

# The onboarding chain's two writes: capture a first name, or skip it.
#
# These are now served by studio-engine (Studio::OnboardingController) — this app
# deleted its own copy and opted into the shared endpoints, so McRitchie Studio
# and McRitchie Industries ask the same question the same way. The behaviour
# asserted below is unchanged; that is the point of the adoption, and the reason
# these tests were kept rather than rewritten.
#
# What is still THIS app's is the SEQUENCE around the step: the `next` array
# comes from config.onboarding_steps_resolver -> OnboardingFlow.
class OnboardingControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:jordan)
    @user.update_columns(first_name: nil, name: nil)
    log_in_as @user
  end

  test "the endpoints are served by the ENGINE, not a local controller" do
    # The adoption's actual claim. Without this, a future local
    # app/controllers/onboarding_controller.rb would silently take the routes
    # back and every other test in this file would still pass.
    recognized = Rails.application.routes.recognize_path(onboarding_first_name_path, method: :post)

    assert_equal "studio/onboarding", recognized[:controller]
    assert_not Object.const_defined?(:OnboardingController),
      "the local copy is deleted — the engine owns these writes now"
  end

  test "capturing a first name writes it and reports what remains" do
    post onboarding_first_name_path, params: { first_name: "Alex" }, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["ok"]
    assert_equal "Alex", body["first_name"]
    assert_equal "Alex", @user.reload.first_name
    assert body.key?("next"), "the client walks the rest of the chain from this"
    assert_not_includes body["next"], "first_name", "the step it just satisfied must be gone"
  end

  test "a blank name is refused rather than silently stored" do
    post onboarding_first_name_path, params: { first_name: "   " }, as: :json
    assert_response :unprocessable_entity
    assert_nil @user.reload.first_name
    assert_match(/skip/i, JSON.parse(response.body)["error"], "the error should point at the skip affordance")
  end

  test "the name is trimmed, inner whitespace collapsed, and length capped" do
    post onboarding_first_name_path, params: { first_name: "  Alex   James#{'x' * 80}  " }, as: :json
    assert_response :success
    # Assert the STORED FULL NAME, not `first_name`. Normalisation — trim,
    # collapse, cap — is what this test is about, and `name` is the column that
    # holds the whole normalised answer under every engine version.
    #
    # `first_name` is NOT that column, and asserting it here pinned a bug rather
    # than a behaviour: the engine wrote the whole typed string into first_name
    # (so "Ada Lovelace" landed first_name="Ada Lovelace", last_name NULL, and
    # never self-healed), which is exactly what made a 40-character first_name
    # look correct. The engine now derives the halves — first_name here is
    # "Alex", 4 characters — so the old assertion failed against the fix while
    # the endpoint was behaving better, not worse.
    stored = @user.reload.name
    # The bound now belongs to the engine's controller — this app deleted its own.
    assert_equal Studio::OnboardingController::MAX_FIRST_NAME, stored.length
    assert stored.start_with?("Alex James"), "expected collapsed whitespace, got #{stored.inspect}"
    # first_name still gets written, and is still the leading part of what was
    # stored — true whether the engine writes the whole value or just the first
    # half, so this keeps the column covered without pinning either shape.
    #
    # The presence guard is LOAD-BEARING, not decoration. `start_with?` alone is
    # vacuous when first_name is blank — "anything".start_with?("") is true — so
    # an engine that stopped writing first_name for a MULTI-WORD name would slip
    # through, and a multi-word name is the exact shape the split exists to get
    # right. Measured: without this line the file stays 10 runs / 0 failures
    # while the writer drops first_name for every value containing a space.
    assert @user.first_name.present?, "first_name should still be written"
    assert stored.start_with?(@user.first_name),
      "first_name #{@user.first_name.inspect} should lead the stored name #{stored.inspect}"
  end

  test "a blank name column is backfilled so display_name has something to show" do
    post onboarding_first_name_path, params: { first_name: "Alex" }, as: :json
    assert_equal "Alex", @user.reload.name
  end

  test "an existing name is NOT overwritten by the first-name capture" do
    @user.update_columns(name: "Alex McRitchie")
    post onboarding_first_name_path, params: { first_name: "Lex" }, as: :json
    assert_equal "Lex", @user.reload.first_name, "the given name is stored"
    assert_equal "Alex McRitchie", @user.name, "a fuller existing name must survive"
  end

  test "the write survives an unrelated invalid attribute on the record" do
    # update_columns, not update!: this lands seconds after signup, and a
    # grandfathered validation problem elsewhere on the row must not cost the
    # user their first name.
    #
    # A too-short username is the right probe here: that length rule is
    # UNCONDITIONAL, so the row reads invalid on every later save. The obvious
    # candidates (a reserved username, a malformed email) are both scoped
    # `if: :*_changed?`, so a row written with update_columns still reports
    # valid? — they would have made this precondition a no-op and the test would
    # have passed without ever exercising the invalid-record path.
    @user.update_columns(username: "ab")
    assert_not @user.reload.valid?, "precondition: the row is invalid for an unrelated reason"
    post onboarding_first_name_path, params: { first_name: "Alex" }, as: :json
    assert_response :success
    assert_equal "Alex", @user.reload.first_name
  end

  test "skipping records the skip and drops the step for the session" do
    post onboarding_skip_first_name_path, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["ok"]
    assert_not_includes body["next"], "first_name"
    assert_nil @user.reload.first_name, "skipping must not write anything"
  end

  test "a skip does not persist to the user, so a later session can ask again" do
    # Session-scoped by design: skipping means not now, not never.
    post onboarding_skip_first_name_path, as: :json
    assert_not_includes JSON.parse(response.body)["next"], "first_name"

    reset!                       # new session, same account
    log_in_as users(:jordan)
    post onboarding_skip_first_name_path, as: :json
    # The field is still blank, so the chain is free to ask again — proven by the
    # resolver seeing it as outstanding in a fresh session.
    assert_includes OnboardingFlow.steps_for(users(:jordan).reload).map(&:to_s), "first_name"
  end

  test "both actions require authentication" do
    reset!
    post onboarding_first_name_path, params: { first_name: "Alex" }, as: :json
    assert_response :unauthorized
    post onboarding_skip_first_name_path, as: :json
    assert_response :unauthorized
  end
end
