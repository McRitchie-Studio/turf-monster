require "test_helper"

# [component] The connect-failure paragraph is a LIVE REGION, and it exists
# before the failure does.
#
# Pre-existing, found while fixing the raw/mapped pair (/tasks/raw-message-is-ours)
# and fixed in the same pass because it is the same paragraph: a screen reader
# was never told the connect failed. The modal's only feedback for a rejected or
# unusable wallet is this sentence, painted with no announcement, after a click
# that otherwise produces silence.
#
# WHY THE MARKUP SHAPE IS THE ASSERTION AND NOT JUST THE ATTRIBUTE. The
# paragraph was `<template x-if="error">`, so it did not exist until the error
# did — and a live region INSERTED alongside its own content is not reliably
# announced, because assistive technology has to be observing the region before
# the text lands in it. Adding aria-live to that markup would have been a green
# test over an unchanged experience. The region is now permanent inside the
# modal and only its VISIBILITY moves.
#
# WHAT THIS TIER CANNOT PROVE: that the sentence actually arrives after the
# region does at runtime. That is e2e/wallet_failure_report.spec.js, which reads
# the empty region while the modal is open and then watches it fill.
class WalletSetupErrorLiveRegionTest < ActiveSupport::TestCase
  MODAL = Rails.root.join("app/views/modals/_wallet_setup.html.erb")

  # THE MARKUP, WITHOUT THE PROSE. ERB comments are stripped first because this
  # file explains the very shape being asserted against — the comment above the
  # paragraph names the `<template x-if="error">` it replaced, and a scan of the
  # raw source finds that sentence and calls it markup. Measured here on
  # 2026-09-07: the refutation below failed on its own explanation.
  def markup
    MODAL.read.gsub(/<%#.*?%>/m, "")
  end

  # The one element that carries the connect failure to the user.
  def error_tag
    markup[/<p[^>]*x-text="error"[^>]*>/]
  end

  test "the error paragraph is announced" do
    tag = error_tag
    assert tag, "the modal must still paint its connect failure into an x-text paragraph"

    assert_includes tag, 'role="alert"',
                    "a connect failure interrupts a user waiting on their own click"
    assert_includes tag, 'aria-live="assertive"',
                    "role=alert implies it, but this file states both (see the install hint above)"
    assert_includes tag, 'aria-atomic="true"',
                    "the sentence is replaced whole, so it is announced whole"
  end

  test "the region exists before the error does" do
    tag = error_tag

    # THE HALF THAT MAKES THE ATTRIBUTES WORK. x-show toggles `display`, leaving
    # the element mounted for the whole life of the modal; x-if would insert it
    # with its content already in place, which is the announcement that never
    # happens.
    assert_includes tag, 'x-show="error"',
                    "the paragraph must be hidden, not absent, before a failure"
    assert_includes tag, "x-cloak",
                    "and must not flash empty before Alpine boots"

    refute_includes markup, '<template x-if="error">',
                    "re-wrapping the paragraph in a template un-announces it silently"
  end

  test "the region carries no text of its own" do
    # An announced region that ships with placeholder copy announces the
    # placeholder. x-text replaces the whole subtree, so the element must be
    # empty in the markup.
    body = markup[/<p[^>]*x-text="error"[^>]*>(.*?)<\/p>/m, 1]

    assert_equal "", body.to_s.strip,
                 "the live region must be empty until Alpine writes the failure into it"
  end
end
