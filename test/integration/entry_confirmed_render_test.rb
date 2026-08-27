# frozen_string_literal: true

require "test_helper"

# [component] The deforked entry card, RENDERED through the real request stack.
#
# Its siblings in engine_modal_defork_test read the adapter's SOURCE — that the
# locals are passed, that it still delegates. Source assertions cannot tell you
# whether the engine DID anything with them: a local the engine ignores, a slot
# name that resolves to nothing, or a partial that raises all look identical to
# a grep.
#
# THE KICKOFF COUNTDOWN is the case that most needs this. The adapter passes
# above_seeds only when kickoff_at is present, which happens only with a contest
# in scope — and every other request spec in this repo renders the card WITHOUT
# one. Before this test the countdown path had no render coverage at all, so
# "above_seeds is passed" was the strongest thing anyone could say about it.
#
# Rendered through a real GET rather than a bare ActionView: the engine card
# composes _success_card WITH A BLOCK, and a hand-built view context cannot
# compile that nesting — the failure is a template-name NoMethodError that looks
# nothing like the delegation bug it would be mistaken for.
class EntryConfirmedRenderTest < ActionDispatch::IntegrationTest
  setup { @contest = contests(:one) }

  test "a contest page renders the entry card with its kickoff countdown" do
    get contest_path(@contest)
    follow_redirect! while response.redirect?
    assert_response :success

    assert_includes response.body, "Entry Confirmed", "the engine card did not render its subtitle"
    assert_includes response.body, "Good Luck", "the pinned headline did not reach the markup"
    assert_includes response.body, "Kicks off in",
                    "the kickoff countdown did not render — above_seeds is passed but the engine " \
                    "never rendered it, so the slot name or the partial path is wrong"
  end

  # THE ESCAPING CHECK. The fork passed HTML entities for the crossed swords;
  # _success_card prints the label through an escaping tag, so entities would
  # reach the page as visible text instead of a glyph.
  test "the CTA label renders as a glyph, not as escaped entity text" do
    get contest_path(@contest)
    follow_redirect! while response.redirect?

    assert_includes response.body, "Contest Lobby", "the CTA label is missing"
    refute_includes response.body, "&amp;#x2694;",
                    "the CTA label reached the page as escaped entity text instead of the emoji"
  end

  # THE DISMISS AFFORDANCE, in the markup rather than in the source — and its
  # listener, without which the button renders and does nothing.
  test "the dismiss button renders and its listener is present" do
    get contest_path(@contest)
    follow_redirect! while response.redirect?

    assert_match(/\$dispatch\('tm-entry-dismiss'\)/, response.body,
                 "the Dismiss button is missing or dispatches nothing")
    assert_match(/x-on:tm-entry-dismiss\.window/, response.body,
                 "nothing on the page listens for the dismiss event the button fires")
  end
end
