require "test_helper"

# [unit] BirthdayModalHelper — the seam between this app's policy/routes and the
# engine's birthday + age-gate cards.
#
# WHY THE WATCH URL GETS A UNIT TEST OF ITS OWN. The engine DROPS the age-gate's
# primary CTA when watch_url is absent, rather than rendering a dead button. That
# is the right engine behaviour and it is also why a nil here is invisible: the
# refusal card still renders, still looks finished, and quietly loses the one
# thing it exists to offer — somewhere to go. A rendered assertion would not
# notice, because nothing is broken on screen.
class BirthdayModalHelperTest < ActionView::TestCase
  include BirthdayModalHelper

  # --- watch_url: the admin's contest, or the index -------------------------

  test "the age gate points at the admin-set main contest when one is open" do
    contest = Contest.where(status: :open).order(created_at: :desc).first
    assert contest, "fixtures must carry an open contest for this to mean anything"
    SeasonConfig.set_main_contest!(contest)

    assert_equal contest_path(contest), age_gate_modal_locals[:watch_url]
  end

  test "the age gate falls back to the contest index when nothing is open" do
    # Off-season, or a fresh deploy with no SeasonConfig row. The CTA must still
    # have a destination: "too young to enter" is not "too young to watch", and
    # a dropped CTA turns the refusal back into the dead end this card replaced.
    Contest.update_all(status: Contest.statuses[:settled])

    assert_nil SeasonConfig.main_contest, "the fallback is only exercised with nothing open"
    assert_equal contests_path, age_gate_modal_locals[:watch_url]
  end

  test "the age gate never supplies its own minimum age" do
    # Deliberate: the engine falls back to props.minAge, which the birthday
    # card's refusal handoff passes. If this helper resolved the bar too, the two
    # cards could disagree — the ask could say 21 while the refusal said 18,
    # which is worse than either being wrong alone.
    locals = age_gate_modal_locals

    assert_not locals.key?(:min_age), "min_age must ride the handoff, not this seam"
    assert_not locals.key?(:state),   "state must ride the handoff, not this seam"
  end

  # --- the birthday card's locals -------------------------------------------

  test "the birthday card gets AgePolicy's minimum for the detected state" do
    def geo_state = "IA"

    locals = birthday_modal_locals
    assert_equal AgePolicy.minimum_age("IA"), locals[:min_age]
    assert_equal "IA", locals[:state]
    assert_equal age_verify_path, locals[:submit_url]
  end

  test "an undetected state still resolves a minimum rather than nil" do
    # geo detection fails open — an unknown visitor must still meet a bar, and
    # min_age nil/0 is a FIRST-CLASS engine mode meaning "ask but do not gate".
    # Falling into it by accident is how the gate would silently stop gating.
    def geo_state = nil

    assert_operator birthday_modal_locals[:min_age].to_i, :>, 0,
      "a blank state must not resolve to the engine's ungated mode"
  end
end
