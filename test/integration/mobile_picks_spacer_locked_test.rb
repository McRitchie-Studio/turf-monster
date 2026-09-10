require "test_helper"

# [component] The mobile picks spacer must clear the bar on a LOCKED contest.
#
# THE DEFECT (found 2026-08-27 by Shannon, reviewing turf PR 453). The spacer
# keyed its height off `selectionCount === picks_required` — a proxy for "the
# CTA is mounted". That proxy is exact in two of the three branches and WRONG in
# the third:
#
#   · the Hold-to-Confirm button is x-shown at a full slate
#   · the Update button (edit mode) is x-shown at a full slate
#   · `🔒 Entries closed` is a SERVER-SIDE `<% if @contest.locked? %>` branch
#     with NO x-show, so it mounts at EVERY selection count
#
# So on a locked contest the bar was already at its tall height while the spacer
# was still reserving the short one. Measured before the fix: 1 pick 173.0px of
# bar against 128px of spacer (-45.0px), 3 picks -45.0px, 5 picks -47.5px, and
# only a full 6 picks (175.5 vs 208) was ever correct. The last pick row sat
# under the fixed bar at any partial slate.
#
# WHY CI COULD NOT SEE IT. `contests(:one)` is `status: open` with `starts_at`
# 30 days out, so neither the locked nor the edit_entry branch is exercised by
# any existing test. This file travels past `starts_at` so `locked?` DERIVES
# true through the real code path (`starts_in_at.present? && Time.current >=
# starts_in_at`) rather than stubbing the predicate — a stub would pass against
# a view that reads some other flag.
class MobilePicksSpacerLockedTest < ActionDispatch::IntegrationTest
  def spacer_for(html)
    i = html.index('data-picks-spacer="mobile"')
    assert i, "the contest page must render the mobile picks spacer"
    html[i, 400]
  end

  def mobile_bar_for(html)
    i = html.index('data-picks-bar="mobile"')
    assert i, "the contest page must render the mobile picks bar"
    html[i..].split("<!-- JSON Debug Block -->").first
  end

  test "an OPEN contest keys the spacer off the slate count" do
    get contest_path(contests(:one))
    assert_response :success

    spacer = spacer_for(response.body)
    assert_includes spacer, "selectionCount ===",
                    "an open contest mounts its CTA only at a full slate, so the spacer " \
                    "must still track the slate count there"
    assert_includes spacer, "height:8rem",
                    "the short height must remain reachable on an open contest"
  end

  test "a LOCKED contest reserves the tall height at EVERY selection count" do
    travel_to contests(:one).starts_at + 1.hour do
      assert contests(:one).reload.locked?,
             "precondition: travelling past starts_at must derive locked? — if this fails " \
             "the rest of this test is asserting against an OPEN contest and proves nothing"

      get contest_path(contests(:one))
      assert_response :success

      spacer = spacer_for(response.body)
      assert_includes spacer, "height:13rem",
                      "a locked contest mounts its CTA at every count, so the spacer must " \
                      "reserve the tall height"
      refute_includes spacer, "selectionCount ===",
                      "the spacer still keys off the slate count on a locked contest — at any " \
                      "partial slate the bar is ~45px taller than the space reserved for it " \
                      "and the last pick row hides under it"
      refute_includes spacer, "height:8rem",
                      "the short height must be unreachable while the CTA is always mounted"
    end
  end

  # THE ROOT CAUSE, pinned. If someone ever gives the locked banner an x-show at
  # a full slate, the branch above stops being special and this file's premise
  # dissolves — better to fail here, loudly, than to keep reserving height for a
  # banner that no longer mounts early.
  test "the locked banner really does mount without an x-show" do
    travel_to contests(:one).starts_at + 1.hour do
      get contest_path(contests(:one))
      assert_response :success

      bar = mobile_bar_for(response.body)
      i = bar.index("Entries closed")
      assert i, "a locked contest must render the Entries closed banner in the mobile bar"

      # the banner's own element, back to the opening tag before it
      open_tag = bar.rindex("<div", i)
      assert open_tag, "could not find the banner's opening tag"
      element = bar[open_tag...i]

      refute_includes element, "x-show",
                      "the Entries closed banner has gained an x-show — the spacer's " \
                      "always-tall branch assumes it mounts unconditionally"
    end
  end
end
