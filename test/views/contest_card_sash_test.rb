# frozen_string_literal: true

require "test_helper"

# [component] THE SASH LAID ACROSS A CONTEST CARD, and the dim layer that goes
# with a coming-soon one.
#
# The card is the featured rail's whole vocabulary, and it has exactly two
# things to say beyond the contest's own details:
#
#   "Entered" / "3 Entries"  you have a stake in this one.
#   "Coming Soon"            this is advertised, not ready.
#
# WHOSE COUNT THE SASH REPORTS IS THE EASIEST THING TO GET WRONG HERE. The card
# already prints the FIELD size in its stat line ("15 entries"), and the page
# has that number to hand as @entry_counts. A sash wired to it would render,
# read plausibly, and be about somebody else — so the multi-entry test below
# gives the viewer a different count from the field's and pins the viewer's.
#
# The dim layer and the sash are two independently breakable halves of "coming
# soon": a card can dim with no label saying why, or be labelled and not dim.
# Both are asserted on the same card, and both are asserted ABSENT on an
# ordinary one, because a layer that renders unconditionally would satisfy
# every positive assertion here.
#
# Elements are addressed by their data-* hooks, never by utility class:
# `.absolute` and `.bg-black/40` are not contracts, and `bg-black/40` in
# particular would silently match any future overlay on the page.
class ContestCardSashTest < ActionDispatch::IntegrationTest
  SASH = "[data-contest-sash]"

  setup do
    @alex = users(:alex)
    @contest = contests(:one)   # alex holds entries(:one); jordan holds entries(:two)
  end

  def card_for(contest)
    "[data-contest-card='#{contest.slug}']"
  end

  test "[component] a contest the viewer entered once is sashed Entered" do
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select "#{card_for(@contest)} [data-contest-sash=entered]", text: "Entered"
  end

  # The count is THE VIEWER'S, not the field's. Alex holds 3 here; the contest
  # holds 4 (jordan's fixture entry makes the field bigger than the viewer's
  # stake), so a sash reading the field would say "4 Entries" and fail.
  test "[component] more than one entry counts them, and counts the viewer's own" do
    log_in_as(@alex)
    2.times { Entry.create!(user: @alex, contest: @contest, status: "active") }

    get contests_path

    assert_response :success
    assert_equal 4, Entry.confirmed.where(contest: @contest).count,
      "the field must be larger than the viewer's stake or this test cannot tell them apart"
    assert_select "#{card_for(@contest)} [data-contest-sash=entered]", text: "3 Entries"
  end

  test "[component] a coming soon contest is sashed and dimmed" do
    @contest.update!(coming_soon: true)
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select "#{card_for(@contest)} [data-contest-sash=soon]", text: "Coming Soon"
    assert_select "#{card_for(@contest)} [data-contest-dim]", count: 1
  end

  # Both facts are true of this contest at once — alex has an entry AND it is
  # flagged coming soon. One sash, and it is the one that tells the reader the
  # contest is not ready.
  test "[component] coming soon outranks entered on the same card" do
    @contest.update!(coming_soon: true)
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select "#{card_for(@contest)} #{SASH}", count: 1
    assert_select "#{card_for(@contest)} [data-contest-sash=soon]", text: "Coming Soon"
  end

  test "[component] an ordinary contest carries neither a sash nor a dim layer" do
    Entry.where(contest: @contest).destroy_all
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select card_for(@contest), count: 1, message: "the card must still be on the rail"
    assert_select "#{card_for(@contest)} #{SASH}", count: 0
    assert_select "#{card_for(@contest)} [data-contest-dim]", count: 0
  end

  # A signed-out reader has no stake in anything, so no card can claim they do.
  # Coming soon is a fact about the CONTEST, so it still shows.
  # The rail holds only open and coming-soon contests, so a status pill on the
  # card made the same claim about every one of them — and took the width the
  # NAME needs. The sash is what still speaks, on the cards that have something
  # to say. Both halves asserted: the badge gone, the sash still there.
  test "[component] a rail card carries no status badge" do
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select "#{card_for(@contest)} [data-contest-badge]", count: 0
    assert_select "#{card_for(@contest)} #{SASH}", count: 1
  end

  # `truncate` is white-space: nowrap + ellipsis, so the class IS the property:
  # a title carrying it cannot reach a second line at any name length. The
  # rendered measurement of the same rule lives in e2e/contests_rail.spec.js,
  # which sweeps every card against a deliberately long fixture name.
  test "[component] a contest name is pinned to one line" do
    @contest.update!(name: "A Deliberately Very Long Operator Typed Contest Name")
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select "#{card_for(@contest)} h2.truncate", count: 1
  end

  test "[component] a signed out reader sees coming soon but never Entered" do
    @contest.update!(coming_soon: true)

    get contests_path

    assert_response :success
    assert_select "#{card_for(@contest)} [data-contest-sash=soon]", text: "Coming Soon"
    assert_select "[data-contest-sash=entered]", count: 0
  end
end
