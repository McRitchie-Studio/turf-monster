# frozen_string_literal: true

require "test_helper"

# [component] A hold has exactly two outcomes: the entry succeeds, or it hands
# off to a blocker and STOPS. Resolving the blocker never resubmits.
#
# WHAT THIS TIER CAN AND CANNOT SEE. These are assertions about inlined JS
# SOURCE TEXT — they prove the listeners are absent, not that a resolved blocker
# fails to submit in a browser. That is the honest limit, and it is why the
# assertions are written as ABSENCE of a call rather than presence of a comment:
# a comment saying "no resume here" would pass while a listener sat beside it.
class HoldNeverResumesTest < ActionDispatch::IntegrationTest
  setup do
    log_in_as(users(:alex))
    @board = File.read(Rails.root.join("app/views/contests/_turf_totals_board.html.erb"))
    @layout = File.read(Rails.root.join("app/views/layouts/application.html.erb"))
  end

  test "the board resumes no entry after a blocker is resolved" do
    %w[first-name-saved age-verified].each do |event|
      listener = @board[/window\.addEventListener\('#{Regexp.escape(event)}'.*?\}\);/m]

      assert_nil listener,
                 "the board listens for '#{event}' — a hold must not resume itself after a " \
                 "blocker is resolved; the player holds again"
    end
  end

  test "the retired resume flag is gone entirely" do
    # _resumeAfterFirstName existed only to stop the post-auth chain's copy of
    # the same event resuming an entry nobody held. With no listener at all,
    # the flag guards nothing — and a flag that guards nothing reads to the next
    # person as though something still depends on it.
    refute_includes @board, "_resumeAfterFirstName",
                    "the resume flag outlived its listener"
  end

  test "the onboarding chain driver survives in the layout" do
    # NOT an entry resume: this one advances the post-auth chain to the wallet
    # step. Deleting it with the others would break the flow a new account meets
    # seconds after signing up, and nothing else would notice.
    assert_includes @layout, "window.addEventListener('age-verified'",
                    "the layout's onboarding CHAIN driver must survive — it is not a resume"
    assert_includes @layout, "__onboardingChainActive",
                    "the chain driver's own guard should still gate it"
  end

  test "every blocker opener still resets the hold button" do
    # This is what makes re-holding possible, and it already held before this
    # change — asserted so that removing the resume never quietly leaves the
    # button stuck in its held or blocked state.
    %w[showFirstNameModal showAgeVerifyModal showWalletSetupModal].each do |opener|
      body = @board[/#{opener}\(\) \{(.*?)\n    \},/m, 1].to_s

      assert_includes body, "resetHoldButtons()",
                      "#{opener} must reset the hold button, or the player cannot hold again " \
                      "after correcting what blocked them"
    end
  end
end
