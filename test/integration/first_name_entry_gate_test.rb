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

  # RENAMED 2026-09-08 — it used to be "...and resumes the entry once, guarded".
  # The resume is gone: a hold now has exactly two outcomes, success or a
  # hand-off to the blocker, and the player holds again (operator rule; see the
  # note where the listeners were in _turf_totals_board). The DISPATCH half of
  # this test is untouched and still the thing worth pinning — the blocker must
  # still route to the card that fixes it.
  test "the board dispatches the first-name blocker to the required card" do
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
    # THE RESUME ASSERTIONS WERE RETIRED HERE, not weakened. They pinned
    # window.addEventListener('first-name-saved') and the _resumeAfterFirstName
    # guard around it — real behaviour, correctly tested, until the rule changed.
    # Their replacement asserts the ABSENCE of that listener and lives in
    # test/integration/hold_never_resumes_test.rb, which also pins the layout's
    # onboarding-chain driver as the thing that must SURVIVE, since it listens
    # for the same event name and is not a resume.
    refute_includes body, "window.addEventListener('first-name-saved'",
                    "the board must not resume an entry after the name is saved"
  end

  # --- 3. the card in required mode -------------------------------------------

  # The two registrations of the `onboarding` id. The card comes from
  # studio-engine now and resolves `required` at RENDER time, so the required and
  # skippable states are two different renders rather than one card switching on
  # a prop — see the registration note in layouts/application.
  def onboarding_registrations(body)
    modal_registration_sources(body, "onboarding")
  end

  # ONE TEST WHERE THERE WERE TWO, and the merge is the whole point of the note
  # this replaces.
  #
  # FOUND BY MUTATION. Until 2026-09-09 the detailed assertions below rendered
  # through /admin/modals/preview, which used layouts/modal_preview — a second
  # layout keeping its OWN registration list. Breaking the required branch in
  # layouts/application, the layout a real player is served, changed nothing
  # here: the mutant survived every test in the file while the entry gate
  # silently served the SKIPPABLE card, complete with a Skip link that records a
  # session skip the gate deliberately ignores. A separate test was added
  # alongside to assert the live layout, and the two then said nearly the same
  # thing about two different pages.
  #
  # Retiring the preview seam removed the second page, so they are one test
  # against the one layout, carrying the union of what each asserted. Not logged
  # in, matching the board assertions above: the registrations are static markup,
  # identical for every viewer, and they live in the layout rather than the page.
  test "the required card drops the skip affordances and keeps a plain close" do
    body = modal_host_page

    cards = onboarding_registrations(body)
    assert_equal 2, cards.length,
                 "layouts/application must register the first-name card twice — the gem resolves " \
                 "`required` at RENDER time, so one registration bakes a single mode for both " \
                 "callers, and a missing branch silently serves the skippable card to the entry " \
                 "gate rather than drawing a blank one. Found #{cards.length}."

    required = cards.find { |c| c.include?(%(aria-label="Close")) }
    assert required,
           "the live layout has no required registration, so the entry gate would open the " \
           "skippable card and offer a way past a validation the hold re-applies"

    assert_includes required, "What should we call you?"

    # OMITTED, NOT HIDDEN, and the change is the point. turf's deleted card
    # x-show'd the skip link off, so the old assertion had to read the BINDING
    # rather than the absence of the words. The engine's card leaves the button
    # out of the render entirely when required, for a reason worth keeping:
    # a control hidden with x-show is still in the DOM, and still clickable, for
    # as long as Alpine has not mounted. So the absence IS now the assertion.
    assert_not_includes required, "Skip for now",
                        "the entry-gate card must not render a skip control at all — the hold " \
                        "cannot proceed without the name, so a Skip link promises a way past a " \
                        "wall that does not move"
    # THE SKIP ENDPOINT IS STILL IN THERE, and that is the gem's design rather
    # than a leak. `skip()` stays defined on the component (with its POST path)
    # when required; what the required render removes is every CONTROL bound to
    # it — the button is not emitted, and the x calls close() instead. So the
    # method is unreachable from the UI, which is the property worth asserting,
    # and asserting the endpoint's ABSENCE would have pinned an implementation
    # detail the gem never promised.
    #
    # And if it were somehow invoked, it would still be safe: skip() finishes
    # with saved:false, and the chain driver's branch only resumes an entry on a
    # save. The two halves cover each other.
    assert_not_includes required, %(@click="skip()"),
                        "nothing in the required card may be wired to skip()"
    assert_includes required, %(@click="$store.modals.close()"),
                    "closing must stay available — a required step abandons the entry, it never " \
                    "traps the user in it"

    # The skippable branch is still there and still skippable, which is what
    # makes the assertions above about the REQUIRED card rather than about the
    # whole page.
    skippable = cards.find { |c| c.include?("Skip for now") }
    assert skippable, "the live layout has no skippable registration for the post-auth chain"
    assert_includes skippable, %(aria-label="Skip")

    # And each branch must be keyed on the PROP, since that is what the two
    # callers differ by — the chain opens with no props, the gate with
    # { required: true }. Without this, both registrations could resolve the
    # same mode and every assertion above would still pass.
    assert_includes body,
                    %(id === 'onboarding' && !!($store.modals.current().props || {}).required)
    assert_includes body,
                    %(id === 'onboarding' && !($store.modals.current().props || {}).required)
  end

  # --- 4. the resume shim, which did NOT graduate into the gem -----------------

  # turf's deleted card cleared $store.session.firstNameRequired and dispatched
  # 'first-name-saved' from save() ONLY. The engine's card fires ONE event for
  # both outcomes and distinguishes them with detail.saved, so the branch moved
  # into the layout's chain driver.
  #
  # THIS TIER IS STRUCTURAL AND SAYS SO. These are assertions about inlined JS
  # SOURCE TEXT: they prove the branch shipped, not that it behaves.
  #
  # This note NAMED THE WRONG MUTANT until 2026-09-07, and the correction makes
  # the point sharper rather than softer. It claimed a negated condition —
  # `if (e && e.detail && !e.detail.saved)` — slips past; it does not, because
  # the assert_includes below pins that literal character-for-character and the
  # `!` breaks it. The mutant that really survives this whole Ruby tier (measured:
  # 26 runs, 213 assertions, 0 failures) keeps EVERY literal intact and simply
  # moves the `window.dispatchEvent` line OUT of the `if` — so every string this
  # file looks for is still present, in order, while a skip resumes an entry whose
  # user still has no name. A source-text tier cannot see a statement that MOVED.
  # The behavioural half is
  # e2e/onboarding_chain.spec.js's "the entry resume fires on a save and not on
  # a skip", which drives the real listener in a real browser.
  test "[component] the chain driver re-dispatches the resume only on a save" do
    get contests_path
    assert_response :success
    body = response.body

    assert_includes body, "if (e && e.detail && e.detail.saved) {",
                    "the re-dispatch must be BRANCHED on the gem's saved flag; unbranched, a " \
                    "skip resumes an entry whose user still has no name"
    assert_includes body, "if (sess) sess.firstNameRequired = false;"
    assert_includes body, "window.dispatchEvent(new CustomEvent('first-name-saved'));"

    # The gem must be the one REPORTING that flag, or the branch reads undefined
    # on every path and silently never fires. This is the consumer half of the
    # 0.72.0 floor recorded on the Gemfile pin.
    assert_operator Gem::Version.new(Studio::VERSION), :>=, Gem::Version.new("0.72.0"),
                    "the onboarding card's done event only carries detail.saved from 0.72.0; " \
                    "below it this branch never fires and a gated entry never resumes"
  end

  test "the chain's card keeps its skip, because a signup is not an entry" do
    # SCOPED TO THE BRANCH, because both registrations are on every page: an
    # unscoped assert_includes for "Skip for now" would pass on the required
    # card's presence alone and prove nothing about this one.
    skippable = onboarding_registrations(modal_host_page).find { |c| c.include?(%(aria-label="Skip")) }
    assert skippable, "the chain's registration must render a Skip-labelled dismiss"
    assert_includes skippable, "Skip for now"
    assert_includes skippable, "/onboarding/skip_first_name"
  end
end
