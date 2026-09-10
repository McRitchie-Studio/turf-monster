require "test_helper"

# The pool the first-name card samples its typed placeholder from.
class OnboardingHelperTest < ActionView::TestCase
  include OnboardingHelper

  test "every entry is a plain first name" do
    # FIRST names only — the field asks for one, so the worked example has to be
    # one. A full name slipping in ("Josh Allen") would type a two-word answer
    # into a field asking for a first name, teaching the wrong thing. It is NOT
    # that the endpoint rejects the space — it accepts "Josh Allen" and derives
    # a surname from it — and this comment used to say otherwise. The space is
    # what makes the length bound below the PER-FIELD one, so this assertion and
    # that one are the same rule read twice.
    OnboardingHelper::QB_FIRST_NAMES.each do |name|
      assert_not_includes name, " ", "#{name.inspect} is not a single first name"
      assert name.present?, "blank entry in the list"
      # BOUND TO THE CAP THESE ENTRIES ACTUALLY MEET, which is not the field's
      # maxlength. Two different caps guard this endpoint, with two different
      # messages, and the assertion above decides which one applies:
      #
      #   Studio::FULL_NAME_MAX_LENGTH (81) — the WHOLE-ANSWER cap. It is the
      #     field's maxlength, and it is derived as (per-field * 2) + 1: first
      #     name, a space, surname. Past it the server answers "Please shorten
      #     that to 81 characters or fewer."
      #   Studio::FIRST_NAME_MAX_LENGTH (40) — the PER-FIELD cap, applied to
      #     each half the server derives from the answer. Past it the server
      #     answers "Please keep each name to 40 characters or fewer."
      #
      # The space assertion above proves every entry here is ONE WORD, and a
      # one-word answer derives to ONE half — so the per-field cap is the only
      # one it can ever hit. Bounding these entries at the WHOLE-ANSWER cap
      # instead would therefore admit every one-word length from
      # FIRST_NAME_MAX_LENGTH + 1 up to and INCLUDING FULL_NAME_MAX_LENGTH —
      # 41 to 81 on today's constants — and the server refuses every one of
      # them. That is a guard weaker than the thing it guards.
      #
      # THE RANGE IS INCLUSIVE AT BOTH ENDS, and this comment used to say
      # "41-to-80". The off-by-one came from reading the whole-answer rule off
      # a SPLIT answer: 82 characters split 40+1+40 is refused whole-answer, so
      # 80 looked like the top of the refused band. It is not, because a
      # one-word 81 PASSES the whole-answer rule and is only then refused
      # per-field. READ IN ORDER: studio-engine's
      # Studio::OnboardingController#length_refusal tests the WHOLE-ANSWER cap
      # FIRST (`value.length > MAX_FULL_NAME`) and the PER-FIELD cap SECOND, so
      # a one-word 81 DOES reach the first rule and passes it — 81 is not > 81
      # — before the second catches it, where its single derived half is
      # 81 > 40. 82 is the first length the FIRST rule stops, which is exactly
      # why the message changes there and not at 81, and why the band's top is
      # the whole-answer cap ITSELF rather than one below it.
      # Re-measured 2026-09-07 against the live endpoint on the resolved
      # engine: one-word 40 accepted; 41 through 81 refused per-field ("Please
      # keep each name to 40 characters or fewer."); 82 and up refused
      # whole-answer ("Please shorten that to 81 characters or fewer.").
      #
      # NO NUMBER HERE IS LOAD-BEARING. Both bounds are read off the constants
      # by the assertion below, and the endpoint's behaviour at both ends of
      # the band is asserted rather than described, by
      # test/integration/onboarding_name_cap_test.rb — which is the only reason
      # a range in prose is safe to write down at all.
      #
      # Hard-coding 40 would be the same mistake in the other direction: the
      # number belongs to the engine and moves with it, and Studio's own comment
      # notes that raising the per-field cap moves the whole-answer cap with it
      # BY CONSTRUCTION. Read the constant, just the right one.
      assert name.length <= Studio::FIRST_NAME_MAX_LENGTH,
             "#{name.inspect} is longer than Studio::FIRST_NAME_MAX_LENGTH " \
             "(#{Studio::FIRST_NAME_MAX_LENGTH}), the PER-FIELD cap the server applies to a " \
             "one-word answer — it would type a placeholder the endpoint then refuses with " \
             "\"Please keep each name to #{Studio::FIRST_NAME_MAX_LENGTH} characters or fewer.\""
    end
  end

  test "the pool is non-empty, because an empty one types nothing" do
    # The card falls back to 'Alex' on an empty pool rather than animating a
    # blank string, but an empty constant here would be a silent downgrade of
    # the whole feature — fail loudly instead.
    assert OnboardingHelper::QB_FIRST_NAMES.any?
    assert_equal OnboardingHelper::QB_FIRST_NAMES, first_name_placeholder_names
  end

  test "the list is frozen, so a sample can never mutate it" do
    assert OnboardingHelper::QB_FIRST_NAMES.frozen?
  end
end
