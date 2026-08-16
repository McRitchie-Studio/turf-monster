require "test_helper"

# The first name as the FIRST validation of hold-to-confirm (operator call,
# 2026-08-15). Before this, a player could hold their way to the age gate, the
# wallet gate and the funding wall with the name still blank — the onboarding
# chain asked once and let a skip stand.
#
# What this tier owns, in the order the pieces have to line up:
#   1. the server publishes firstNameRequired on the session payload, derived
#      from the COLUMN (a session skip must not buy anyone past a validation);
#   2. eligibilityBlocker returns first_name_required AHEAD of age, wallet and
#      funding;
#   3. the board dispatches that reason to the required-mode card and resumes
#      the entry only when IT opened the card;
#   4. the card in required mode offers no way to skip.
#
# NOT owned here, deliberately: a server-side refusal. A first name is how we
# address someone in an email, not a compliance or capability property, so
# ContestsController#enter still accepts an entry without one — unlike the age
# and wallet gates, whose server twins exist because an entry past them is
# illegal or unsignable. e2e/onboarding_chain.spec.js proves the live ordering.
class FirstNameEntryGateTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
  end

  teardown do
    Rails.cache.clear
  end

  def session_payload
    JSON.parse(response.body[/id="session-context"[^>]*>(\{.*?\})<\/script>/m, 1])
  end

  # --- 1. the server side of the gate ----------------------------------------

  test "the session payload asks for a first name while the column is blank" do
    user = users(:jordan)
    user.update_columns(first_name: nil, name: nil)
    log_in_as user

    get contests_path
    assert_response :success
    assert_equal true, session_payload["firstNameRequired"]
  end

  test "a saved first name clears it" do
    user = users(:jordan)
    user.update_columns(first_name: "Jordan")
    log_in_as user

    get contests_path
    assert_response :success
    assert_equal false, session_payload["firstNameRequired"]
  end

  test "a session SKIP does not clear it" do
    # THE distinction this gate rests on. OnboardingFlow drops the first_name
    # step for the rest of the session the moment the user skips, so a chain-
    # derived flag would wave a skipper straight through the entry validation.
    # This one reads the column, so the skip changes the ASK and not the GATE.
    user = users(:jordan)
    user.update_columns(first_name: nil, name: nil)
    log_in_as user
    post "/onboarding/skip_first_name", as: :json
    assert_response :success

    get contests_path
    assert_response :success
    assert_equal true, session_payload["firstNameRequired"],
                 "skipping the ask must not satisfy the entry validation"
    assert_not_includes OnboardingFlow.steps_for(user.reload, skipped_first_name: true), :first_name,
                        "precondition: the CHAIN really did drop the step"
  end

  test "a guest is not asked — the login gate comes first" do
    get contests_path
    assert_response :success
    assert_equal false, session_payload["firstNameRequired"],
                 "a guest has no column to read; not_logged_in is their blocker"
  end

  # --- 2. the client ordering -------------------------------------------------

  test "eligibilityBlocker returns first_name_required before every other gate" do
    # eligibilityBlocker ships as an importmap module, not inlined in the page,
    # so assert against the source — the same seam wallet_topup_test.rb uses.
    # ORDER is the whole subject here, so assert the POSITIONS, not just that
    # each branch exists: a first-name check that lands after the age check is
    # exactly the bug this change removes, and every string below would still be
    # present.
    src = Rails.root.join("app/javascript/solana_utils.js").read
    first_name = src.index("reason: 'first_name_required'")
    age        = src.index("reason: 'age_required'")
    wallet     = src.index("reason: 'wallet_setup_required'")
    funding    = src.index("reason: 'no_funding'")

    assert first_name, "eligibilityBlocker must return a first_name_required blocker"
    assert first_name < age,     "the name must be asked before the DOB"
    assert first_name < wallet,  "the name must be asked before the wallet"
    assert first_name < funding, "the name must be asked before money"
  end

  test "the board dispatches the blocker and resumes the entry once, guarded" do
    # NOT logged in, on purpose (same as wallet_topup_test's board assertions):
    # this markup is static component source, identical for every viewer, and a
    # user who already HAS an entry on this contest renders the entries view
    # instead of the picks board — so signing in here would assert against a page
    # that never contains the dispatcher.
    get contest_path(contests(:one))
    assert_response :success
    body = response.body

    assert_includes body, "case 'first_name_required':  this.showFirstNameModal(); break;"
    assert_includes body, "Alpine.store('modals').open('onboarding', { required: true, enterAnim: 'shake' });"
    # The resume, and the guard that keeps the post-auth chain from firing it.
    # Both matter: the chain opens the same modal and dispatches the same event,
    # so an unguarded listener would submit a lineup nobody held.
    assert_includes body, "window.addEventListener('first-name-saved', function () {"
    assert_includes body, "if (!board._resumeAfterFirstName) return;"
    assert_includes body, "board._resumeAfterFirstName = false;"
  end

  # --- 3. the card in required mode -------------------------------------------

  test "the required card drops the skip affordances and keeps a plain close" do
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "onboarding", props: { required: true }.to_json)
    assert_response :success

    assert_includes response.body, "What should we call you?"
    # The skip link is x-show'd off rather than deleted — one card, two callers —
    # so assert the BINDING that hides it, not the absence of the words.
    assert_includes response.body, 'x-show="!required"'
    assert_includes response.body, %(@click="required ? $store.modals.close() : skip()")
    # And the save still clears the store flag the resumed hold will read.
    assert_includes response.body, "sess.firstNameRequired = false;"
    assert_includes response.body, "first-name-saved"
  end

  test "the chain's card keeps its skip, because a signup is not an entry" do
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "onboarding", props: {}.to_json)
    assert_response :success
    assert_includes response.body, "Skip for now"
    assert_includes response.body, "/onboarding/skip_first_name"
  end
end
