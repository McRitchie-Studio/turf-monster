require "test_helper"

# The onboarding first-name field's length cap, asserted against RENDERED HTML.
#
# THE BUG THIS REGRESSES. turf's own onboarding card (the since-deleted
# app/views/modals/_onboarding.html.erb) hard-coded maxlength="40". That number
# is Studio::FIRST_NAME_MAX_LENGTH — the PER-FIELD cap, what one derived half may
# be — and this field asks for a whole name.
# "Bartholomew Fitzwilliam Montgomery-Smythe" is 41 characters, so the browser
# clamped it to a LEGAL 40-character answer whose two halves both fit the
# per-field cap. The server therefore had nothing to refuse: 200 OK, and the
# account was handed back its own surname misspelled as "Montgomery-Smyth".
# Nothing raised, nothing logged, no 422 — the name was gone before the request
# was made. studio-engine PR #275 fixed the shared partial, but this app rendered
# its OWN onboarding modal at the time, so the fix never reached here.
#
# THAT FORK IS NOW GONE: turf-adopts-first-name deleted the local card and this
# app renders the engine's studio/modals/onboarding/first_name, which reads the
# constant itself. These assertions therefore changed meaning without changing
# shape — they no longer guard against a re-hardcoded literal in this repo, they
# guard the ADOPTION: that what this app actually serves still carries the cap,
# on BOTH registered branches. A gem that regressed the attribute, or a locals
# change here that overrode max_length, lands in exactly the same place.
#
# WHY THESE ASSERTIONS ARE RENDERED, NOT GREPPED. The guards that already exist
# around this modal read the .erb file as a STRING (see onboarding_gallery_test's
# x-data check, which has to work that way). A source grep is documentary: it
# passes on a view that has stopped emitting the attribute at all, and it passes
# on a view whose ERB raises before reaching it. Measured before this file was
# written — there was no rendered maxlength assertion anywhere in this suite, so
# the attribute could be deleted outright and the suite stayed green. Both tests
# below therefore parse the real response body and read the real attribute off
# the real element.
#
# WHY NO NUMBER APPEARS BELOW. Neither test names 40 or 81. The first compares
# the rendered attribute to the engine constant, so an engine that moves the cap
# moves both sides together. The second compares the rendered attribute to what
# the endpoint MEASURABLY does with a name of that length, so it reads both
# bounds live. Neither can deadlock a studio-engine release — the deliberate
# property that made onboarding_controller_test drop its own length assertions.
class OnboardingNameCapTest < ActionDispatch::IntegrationTest
  # The modal as a browser receives it, off an ordinary page on
  # layouts/application. This used to go through /admin/modals/preview, whose
  # layout kept a SECOND registration of the same engine partial — so a cap that
  # reached the preview's registration and not the app's would have measured
  # green here while every real player got an uncapped field. That seam was
  # retired on 2026-09-09 and this reads the only registration list left.
  #
  # BOTH BRANCHES, not the first one found. The card is registered twice
  # (skippable + required; see the note in layouts/application), and they are
  # separate render calls with separate locals — so a max_length that reached one
  # and not the other is a real and otherwise invisible outcome. at_css would
  # have silently measured whichever came first.
  def rendered_first_name_fields
    body = modal_host_page

    fields = Nokogiri::HTML(body).css("#onboarding-first-name")
    assert_equal 2, fields.length,
                 "expected the first-name input on BOTH registrations; found #{fields.length}"
    fields
  end

  # The one a browser mounts for the CHAIN caller, for the tests that only need
  # a single representative field.
  def rendered_first_name_field
    rendered_first_name_fields.first
  end

  # --- [component] the rendered bound -----------------------------------------

  test "the rendered first-name field caps at the WHOLE-ANSWER length" do
    rendered_first_name_fields.each { |f| assert_whole_answer_cap(f) }
  end

  def assert_whole_answer_cap(field)
    # Present at all. Read explicitly rather than folded into the comparison
    # below, because a missing attribute and a wrong one are different bugs and
    # the failure message should say which happened.
    assert field["maxlength"].present?,
           "the field renders no maxlength — the browser would accept any length, " \
           "and this assertion exists because deleting the attribute used to be invisible"

    # Bound to the constant, not to a copy of its value. Studio derives
    # FULL_NAME_MAX_LENGTH as first(FIRST_NAME_MAX_LENGTH) + a space +
    # last(FIRST_NAME_MAX_LENGTH), so it is the longest answer whose two halves
    # both still fit the per-field cap — onboarding can never accept a name
    # /profile would later shorten. Comparing against the constant means a
    # re-hardcoded literal passes today and goes red the moment the engine moves
    # the cap, which is precisely when the drift starts costing names.
    assert_equal Studio::FULL_NAME_MAX_LENGTH.to_s, field["maxlength"],
                 "the field must read Studio::FULL_NAME_MAX_LENGTH. " \
                 "Studio::FIRST_NAME_MAX_LENGTH (#{Studio::FIRST_NAME_MAX_LENGTH}) is a different " \
                 "question — what ONE derived half may be — and using it here is the bug " \
                 "that truncated Montgomery-Smythe"
  end

  # --- [integration] the two bounds agree -------------------------------------

  test "what the browser allows is exactly what the endpoint accepts" do
    cap = rendered_first_name_field["maxlength"].to_i
    assert cap.positive?, "no rendered cap to measure the server against"

    user = users(:jordan)
    user.update_columns(first_name: nil, name: nil)
    log_in_as user

    # A name of EXACTLY the rendered length, split so both halves clear the
    # per-field cap — otherwise the endpoint's second guard fires and this would
    # measure the wrong rule.
    half = (cap - 1) / 2
    at_cap = "#{'a' * half} #{'b' * (cap - 1 - half)}"
    assert_equal cap, at_cap.length

    post onboarding_first_name_path, params: { first_name: at_cap }, as: :json
    assert_response :success,
                    "the browser let this through, so the server must not lose it — " \
                    "a browser bound TIGHTER than the server is how the name vanished silently"
    assert_equal at_cap, user.reload.name,
                 "stored in full — the whole point is that nothing is quietly shortened"

    # And one character past it is refused rather than truncated, so the browser
    # bound is not looser than the server's either.
    post onboarding_first_name_path, params: { first_name: "#{at_cap}c" }, as: :json
    assert_response :unprocessable_entity,
                    "past the rendered cap the server must refuse, not rewrite the answer"
    assert_equal at_cap, user.reload.name, "the refused answer must not have overwritten the stored one"
  end

  # THE OTHER GUARD, which the test above deliberately steers around. Its
  # comment says so: it splits its answer "so both halves clear the per-field
  # cap — otherwise the endpoint's SECOND guard fires and this would measure the
  # wrong rule." That second guard was therefore never measured here at all, and
  # something now depends on it: test/helpers/onboarding_helper_test.rb bounds
  # every typed placeholder by Studio::FIRST_NAME_MAX_LENGTH, on the grounds
  # that a ONE-WORD answer derives to one half and can only ever meet the
  # per-field cap. That is a claim about this endpoint, so this asserts it here
  # rather than leaving it as reasoning in a comment two files away.
  #
  # It is also the assertion that keeps the two caps from being confused again.
  # An unsplit answer one character past the per-field cap is still far BELOW
  # the whole-answer cap, so a 422 alone would not say which rule fired — the
  # message is what distinguishes them, and both are read off the constants so
  # no number is written down here either.
  test "a one-word answer is bounded by the per-field cap, not the whole-answer cap" do
    user = users(:jordan)
    user.update_columns(first_name: nil, name: nil)
    log_in_as user

    at_cap = "a" * Studio::FIRST_NAME_MAX_LENGTH

    post onboarding_first_name_path, params: { first_name: at_cap }, as: :json
    assert_response :success,
                    "a single word of exactly Studio::FIRST_NAME_MAX_LENGTH must be accepted — " \
                    "it is the longest one-word answer the endpoint can store"
    assert_equal at_cap, user.reload.name, "stored in full, not shortened"

    over = "#{at_cap}a"
    assert_operator over.length, :<, Studio::FULL_NAME_MAX_LENGTH,
                    "this probe has to sit BELOW the whole-answer cap, or it would be measuring " \
                    "that guard instead of the per-field one"

    post onboarding_first_name_path, params: { first_name: over }, as: :json
    assert_response :unprocessable_entity,
                    "one word past the per-field cap must be refused even though it is well " \
                    "under the whole-answer cap — that is the whole difference between the two"

    error = response.parsed_body["error"].to_s
    assert_includes error, Studio::FIRST_NAME_MAX_LENGTH.to_s,
                    "the refusal must name the PER-FIELD cap (#{Studio::FIRST_NAME_MAX_LENGTH}); " \
                    "it said #{error.inspect}"
    assert_not_includes error, Studio::FULL_NAME_MAX_LENGTH.to_s,
                    "the whole-answer cap (#{Studio::FULL_NAME_MAX_LENGTH}) is NOT the rule that " \
                    "fired here — if it is, a one-word placeholder bounded at the per-field cap " \
                    "is bounded by the wrong constant"
    assert_equal at_cap, user.reload.name, "the refused answer must not have overwritten the stored one"
  end

  # ── [integration] THE TOP OF THE REFUSED BAND ────────────────────────────
  #
  # THE OFF-BY-ONE THIS EXISTS FOR. test/helpers/onboarding_helper_test.rb
  # argues that a typed placeholder must be bounded by the PER-FIELD cap rather
  # than the whole-answer one, and it described what the looser bound would
  # admit as "a 41-to-80 character placeholder". The top of that range was wrong
  # by one. The reasoning read the whole-answer rule off a SPLIT answer — 82
  # characters split 40+1+40 is refused whole-answer, so 80 looked like the last
  # refused length — but a ONE-WORD answer of exactly the whole-answer cap
  # PASSES that rule and is refused by the per-field one after it.
  # length_refusal tests the whole-answer cap FIRST and the per-field cap
  # SECOND, so at exactly the cap the first test (`> MAX_FULL_NAME`) is false,
  # the answer falls through, and its one derived half is over the per-field
  # cap. The band's top is 81 because of what the SECOND rule catches, not
  # because the first was never reached.
  #
  # SAME LENGTH, DIFFERENT SHAPE, DIFFERENT RULE, and that is the whole
  # confusion in one sentence. At exactly Studio::FULL_NAME_MAX_LENGTH the split
  # answer is ACCEPTED and the one-word answer is REFUSED, so a length alone
  # never says which rule applies. The test above measures the split case; this
  # measures the unsplit one, and asserts them against each other so the pair
  # cannot drift apart.
  #
  # NO NUMBER IS WRITTEN DOWN, for the same reason as every other test in this
  # file: both bounds come off the engine constants, so an engine that moves
  # either cap moves this test with it instead of deadlocking a release.
  test "a one-word answer at the WHOLE-ANSWER cap is refused by the PER-FIELD rule" do
    user = users(:jordan)
    user.update_columns(first_name: nil, name: nil)
    log_in_as user

    unsplit = "a" * Studio::FULL_NAME_MAX_LENGTH
    assert_equal Studio::FULL_NAME_MAX_LENGTH, unsplit.length
    assert_not_includes unsplit, " ", "this probe only means anything while the answer is ONE word"

    post onboarding_first_name_path, params: { first_name: unsplit }, as: :json
    assert_response :unprocessable_entity,
                    "a one-word answer of exactly Studio::FULL_NAME_MAX_LENGTH " \
                    "(#{Studio::FULL_NAME_MAX_LENGTH}) must be refused — it derives to a single " \
                    "half far past the per-field cap, so the top of the refused band for a " \
                    "one-word answer is the whole-answer cap ITSELF, not one below it"

    error = response.parsed_body["error"].to_s
    assert_includes error, Studio::FIRST_NAME_MAX_LENGTH.to_s,
                    "the refusal must name the PER-FIELD cap — that is the rule that fires, and " \
                    "the reason this length is refused at all; it said #{error.inspect}"
    assert_equal unsplit.length, Studio::FULL_NAME_MAX_LENGTH,
                 "and the length that got refused is the whole-answer cap, which is the fact the " \
                 "helper test's range depends on"
    assert_nil user.reload.name, "the refused answer must not have been stored"

    # THE CONTROL, and it is the discriminating one rather than decoration. The
    # SAME LENGTH, split so both halves clear the per-field cap, is ACCEPTED. So
    # the refusal above is about the SHAPE of the answer and not about its
    # length — without this, "81 is refused" and "81 is accepted" look like a
    # contradiction instead of the two rules they actually are.
    half  = (Studio::FULL_NAME_MAX_LENGTH - 1) / 2
    split = "#{'a' * half} #{'b' * (Studio::FULL_NAME_MAX_LENGTH - 1 - half)}"
    assert_equal unsplit.length, split.length, "the control has to be the SAME length to control anything"

    post onboarding_first_name_path, params: { first_name: split }, as: :json
    assert_response :success,
                    "the same length split into two per-field-legal halves must be ACCEPTED — if " \
                    "it is not, the refusal above is about length after all and this file's whole " \
                    "two-rule reading is wrong"
    assert_equal split, user.reload.name

    # AND ONE CHARACTER FURTHER, the OTHER rule takes over. This is the boundary
    # the old prose mistook for the top of the per-field band.
    user.update_columns(first_name: nil, name: nil)
    over = "a" * (Studio::FULL_NAME_MAX_LENGTH + 1)

    post onboarding_first_name_path, params: { first_name: over }, as: :json
    assert_response :unprocessable_entity
    over_error = response.parsed_body["error"].to_s
    assert_includes over_error, Studio::FULL_NAME_MAX_LENGTH.to_s,
                    "one past the whole-answer cap must be refused by the WHOLE-ANSWER rule — " \
                    "that is the first length at which it fires for a one-word answer, and it " \
                    "is the boundary the helper test's range stops below"
    assert_not_equal error, over_error,
                     "the two lengths must be refused by DIFFERENT rules with different messages " \
                     "— identical messages would mean only one rule is reachable and the band " \
                     "described in the helper test does not exist"
  end
end
