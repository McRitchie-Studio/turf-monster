require "test_helper"

# [component] shared/_alpine_turbo_cache_reset — the partial that keeps Alpine's
# GENERATED nodes out of Turbo's page cache.
#
# The bug it exists for: 6 of 6 picks, follow a link, press Back, and "Your
# Picks" shows twelve rows. Turbo snapshots the live DOM including the rows
# x-for produced, Alpine's record of them is a JS property that does not survive
# the snapshot, so the restored page renders a second set beside the cached one.
#
# What a component tier can and cannot prove: it CANNOT prove the sweep works —
# that needs a real Turbo restoration visit and a real Alpine re-init, which is
# e2e/pick_slots_turbo_restore.spec.js's job. What it CAN prove, and what no
# browser spec in this app would catch on a lane that skipped it, is that the
# script is WIRED: present in the page, listening on the right event, and
# covering both template kinds. A silently dropped render line disables the fix
# with nothing failing anywhere.
class AlpineTurboCacheResetTest < ActionView::TestCase
  def partial
    render partial: "shared/alpine_turbo_cache_reset"
  end

  test "it listens on turbo:before-cache" do
    html = partial

    assert_includes html, "turbo:before-cache",
                    "the sweep has to run before Turbo takes its snapshot"
    refute_includes html, "pageshow",
                    "bfcache restores the JS heap, Alpine never re-inits, and " \
                    "nothing duplicates — sweeping there would delete live rows " \
                    "with nothing left to re-render them"
  end

  test "it sweeps both template kinds, x-for before x-if" do
    html = partial

    for_at = html.index("template[x-for]")
    if_at = html.index("template[x-if]")

    assert for_at, "x-for is the kind the operator's twelve rows came from"
    assert if_at, "x-if clones duplicate by the same mechanism"
    assert for_at < if_at,
           "x-for must be swept FIRST: an x-for row can contain x-if templates, " \
           "and removing the row takes its nested templates with it"
  end

  test "it clears the bookkeeping that points at the removed nodes" do
    html = partial

    assert_includes html, "_x_lookup", "x-for tracks generated rows here"
    assert_includes html, "_x_currentIfEl", "x-if tracks its single clone here"
  end

  test "it registers once, however many times Turbo re-runs the body" do
    html = partial

    assert_includes html, "__turfAlpineTurboCacheReset",
                    "body scripts re-execute on every Turbo swap; without the " \
                    "guard the sweep stacks up a listener per navigation"
  end
end
