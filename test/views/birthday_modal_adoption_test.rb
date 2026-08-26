require "test_helper"

# [component] The birthday card, after this app stopped carrying its own copy.
#
# WHAT THIS REPLACED. test/views/age_verify_shared_field_test.rb guarded the
# previous step of the same migration: this app owned modals/_age_verify and had
# merely stopped forking the three DOB selects inside it. studio-engine 0.60.1
# homes the WHOLE card (studio/modals/blocks/_birthday), so that file's subject —
# a local modal plus a local ageVerifyModal factory — no longer exists. The
# factory internals it asserted (onMonthChange, the day clamp) are the engine's
# tests now; what is left for this app to defend is the SEAM.
#
# THE SEAM IS THE POLICY. The engine hardcodes no legal rule: it takes a resolved
# minimum and a passive jurisdiction label. If this app ever stops threading
# AgePolicy through, the card still renders — it just stops gating, silently, on
# a page that looks correct. That is the failure worth a test.
# geo_state is a CONTROLLER helper_method (Studio::GeoDetection), so it is absent
# from a view-only render. BirthdayModalHelper calls it, and a `locals:` entry
# cannot shadow a call made inside a helper module — which is why the deleted
# test's approach of passing geo_state as a local does not carry over. Back it
# with an explicit accessor instead of an ivar: the test case and the view
# context are different objects, so an ivar set here is not the one the helper
# reads.
module BirthdayGeoStateStub
  mattr_accessor :value

  def geo_state
    BirthdayGeoStateStub.value
  end
end

class BirthdayModalAdoptionTest < ActionView::TestCase
  helper BirthdayModalHelper
  helper BirthdayGeoStateStub

  DELETED_FORK = Rails.root.join("app/views/modals/_age_verify.html.erb")

  # ActionView::TestCase#rendered ACCUMULATES across calls, so every refute below
  # would pass vacuously off the union of renders. Use the return value.
  def render_card(state: "IA")
    BirthdayGeoStateStub.value = state
    render partial: "modals/birthday"
  end

  # --- the card is the engine's -----------------------------------------------

  test "the card mounts the engine factory, not a local one" do
    html = render_card

    assert_includes html, "x-data=\"birthdayModal({",
      "the card must mount the engine's window.birthdayModal factory"
    assert_not_includes html, "ageVerifyModal",
      "this app's own factory was deleted with the fork; a mention means it came back"
  end

  test "the local fork is gone from disk" do
    # A render assertion cannot answer this: a fork and a shared render produce
    # the same markup, which is what let the duplication survive so long.
    assert_not File.exist?(DELETED_FORK),
      "#{DELETED_FORK.basename} is back — the engine owns this card now"
  end

  test "the engine's date-of-birth field still renders through the card" do
    html = render_card

    %w[month day year].each do |part|
      assert_match(/x-model="#{part}"/, html, "the #{part} select did not render")
    end
    assert_includes html, 'x-for="m in months"'
    assert_includes html, 'x-for="d in dayOptions"'
    assert_includes html, 'x-for="y in years"'
  end

  # --- the seam: this app's policy and this app's endpoint --------------------

  test "the card bakes in this app's age policy and endpoint" do
    html = render_card(state: "IA")

    assert_includes html, "minAge: #{AgePolicy.minimum_age('IA')}",
      "the engine takes a RESOLVED minimum; this app must supply AgePolicy's"
    assert_includes html, "state: 'IA'"
    assert_includes html, "url: '#{age_verify_path}'"
    assert_includes html, "in IA", "the copy names the state the minimum came from"
    assert_includes html, "19+ AL/NE; 21+ IA/MA/VA",
      "the per-state age table is this app's legal copy; the engine ships only a "\
      "policy-free default, so a dropped fine_print silently removes it"
  end

  test "a state with a different bar renders that different bar" do
    # Guards the one failure a single-state test cannot see: a hardcoded number
    # that happens to match the state the other test picked. Chosen by asking
    # AgePolicy which states actually disagree rather than assuming any pair do.
    a = "IA"
    b = AgePolicy::MINIMUM_AGE_BY_STATE.keys.find { |s|
      AgePolicy.minimum_age(s) != AgePolicy.minimum_age(a)
    }
    skip "no jurisdiction disagrees with #{a} in this policy" if b.nil?

    assert_includes render_card(state: a), "minAge: #{AgePolicy.minimum_age(a)}"
    assert_includes render_card(state: b), "minAge: #{AgePolicy.minimum_age(b)}"
  end

  # --- the refusal handoff ----------------------------------------------------

  test "the card hands a refusal to the age-gate id" do
    # The engine swaps to gateId on the server's underage verdict. A blank gateId
    # is a first-class engine mode (the refusal falls back to the inline error
    # line), so this asserts the id is actually threaded rather than defaulted
    # into the mid-adoption behaviour this app is no longer in.
    assert_includes render_card, "gateId: 'age-gate'",
      "without the gate id the refusal degrades to a red line — the dead end " \
      "the two cards were split up to remove"
  end

  # --- the chain pill ---------------------------------------------------------

  test "the chain pill reads 2 of 3 and sits above the card" do
    html = render_card

    # The pill has no digits — it encodes the step as FILLED bars, so read the
    # bars. Asserting a "2" would have passed off the minAge of a 21+ state.
    pill = html[%r{<div class="flex items-center justify-center gap-1\.5.*?</div>\s*</div>}m]
    assert pill, "the chain pill did not render"
    assert_equal 2, pill.scan("rounded-full bg-primary").size,
      "step 2 of 3 means exactly two filled bars"
    assert_equal 1, pill.scan("rounded-full bg-inset").size,
      "step 2 of 3 means exactly one unfilled bar"

    # ORDER, not mere presence. The pill moved OUT of the shell when this app
    # adopted the engine card (the engine block has no yield slot), and above the
    # title is where the chain's other two steps already put theirs. A pill that
    # rendered BELOW the title would still pass a presence check while looking
    # unlike steps 1 and 3.
    assert_operator html.index(pill), :<, html.index("Your birthday"),
      "the pill must read above the card's title, matching steps 1 and 3"
  end
end
