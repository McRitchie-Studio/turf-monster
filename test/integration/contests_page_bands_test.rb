# frozen_string_literal: true

require "test_helper"

# [integration] /contests IS THREE BANDS, and each answers a different question.
#
#   1. the featured rail   what can I play right now?
#   2. My Contests         where do I stand in the ones I'm in?
#   3. All Contests        the full list, plus the controls that act on it.
#
# The redesign moved the reader's own contests OUT of the top slot: the rail
# there is now the page's headline and carries no heading at all, and My
# Contests became a table below it. So the top band is asserted to hold
# contests the viewer has NOT entered — under the old layout it could only ever
# hold entered ones, and every "the rail renders" assertion would pass against
# the page this replaced.
#
# THE SAME CONTEST IS READ TWICE ON THIS PAGE, and the two readings must
# differ. In My Contests a settled contest reports how it ENDED for this viewer
# — Won or Complete, and the amount they took home. In All Contests, which is
# nobody's ledger, it stays the plain "Settled" with the guaranteed pool. Every
# badge and prize assertion below therefore names its band; an assertion that
# did not would pass on whichever copy it happened to match first.
#
# And the two bands disagree about settled rows on purpose: All Contests hides
# them behind the admin toggle (they are noise in a list of what to play), My
# Contests always shows them (a finished contest's result is the only thing
# that band exists to report). That is asserted as a PAIR — a table that hides
# nothing satisfies the My Contests half on its own.
class ContestsPageBandsTest < ActionDispatch::IntegrationTest
  MINE = "[data-contest-band=mine]"
  ALL  = "[data-contest-band=all]"
  RAIL = "[data-contest-band=featured]"

  setup do
    @alex   = users(:alex)     # admin
    @jordan = users(:jordan)
    @open   = contests(:one)   # alex holds entries(:one)
  end

  def build_contest(slug, status: "open", coming_soon: false, created_at: 1.day.ago)
    Contest.create!(
      name: slug.titleize, slug: slug, status: status, coming_soon: coming_soon,
      entry_fee_cents: 1900, max_entries: 29, contest_type: "standard",
      slate: slates(:one), created_at: created_at
    )
  end

  # --- Band 1: the featured rail ----------------------------------------

  test "[integration] the rail leads the page and carries no heading" do
    get contests_path

    assert_response :success
    assert_select "#{RAIL} [data-contest-rail]", count: 1
    # A DIRECT child h2 only: each card carries its own <h2> for the contest
    # name, so an unscoped "#{RAIL} h2" matches the cards and can never be zero.
    # What must not exist is a SECTION heading over the rail.
    assert_select "#{RAIL} > h2", count: 0,
      message: "the rail is the page's headline — a heading above it only pushes the contests down"
    assert_no_match(/My Contests/, css_select(RAIL).first.to_html,
      "the reader's own contests moved to their own band below; the rail must not be labelled with them")
  end

  # Under the old layout the top band was My Contests, so it could hold only
  # contests the viewer had entered. This one is entered by nobody.
  test "[integration] the rail shows contests the viewer has not entered" do
    stranger = build_contest("nobody-has-entered-this")
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select "#{RAIL} [data-contest-card='#{stranger.slug}']", count: 1
  end

  test "[integration] a settled contest is off the rail but still in All Contests" do
    done = build_contest("finished-up", status: "settled")

    get contests_path

    assert_response :success
    assert_select "#{RAIL} [data-contest-card='#{done.slug}']", count: 0
    assert_select "#{ALL} [data-contest-row='#{done.slug}']", count: 1
  end

  # --- Band 2: My Contests ----------------------------------------------

  test "[integration] My Contests is a table of the contests the viewer is in" do
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select "#{MINE} table", count: 1
    assert_select "#{MINE} [data-contest-row='#{@open.slug}']", count: 1
  end

  test "[integration] My Contests is hidden entirely from a reader with no entries" do
    log_in_as(users(:sam))

    get contests_path

    assert_response :success
    assert_select MINE, count: 0
  end

  test "[integration] a settled contest the viewer won badges Won and shows what they won" do
    won = build_contest("took-the-pot", status: "settled")
    Entry.create!(user: @alex, contest: won, status: "complete", payout_cents: 25_000)
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select "#{MINE} [data-contest-row='#{won.slug}'] [data-contest-badge]", text: "Won"
    assert_select "#{MINE} [data-contest-row='#{won.slug}'] [data-contest-prize]", text: "$250.00"
  end

  # The pool is KEPT rather than blanked — "$X was on the table" is the point —
  # and the grey is what says it went elsewhere. The green class is asserted
  # absent because the colour is the entire message here: the same number in
  # green would read as money won.
  test "[integration] a settled contest the viewer lost keeps the pool and greys it out" do
    lost = build_contest("slipped-away", status: "settled")
    Entry.create!(user: @alex, contest: lost, status: "complete", payout_cents: 0)
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select "#{MINE} [data-contest-row='#{lost.slug}'] [data-contest-badge]", text: "Complete"
    assert_select "#{MINE} [data-contest-row='#{lost.slug}'] [data-contest-prize].text-muted", count: 1
    assert_select "#{MINE} [data-contest-row='#{lost.slug}'] [data-contest-prize].text-primary", count: 0
  end

  test "[integration] My Contests shows its settled rows without the admin toggle" do
    done = build_contest("already-over", status: "settled")
    Entry.create!(user: @alex, contest: done, status: "complete", payout_cents: 0)
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select "#{MINE} [data-contest-row='#{done.slug}']", count: 1
    assert_select "#{MINE} [data-contest-row='#{done.slug}'][x-show]", count: 0,
      message: "a finished contest's result is the only thing this band reports — it cannot be behind a toggle"
    # The pair: the same contest IS behind the toggle in All Contests.
    assert_select "#{ALL} [data-contest-row='#{done.slug}'][x-show]", count: 1
  end

  # --- The band switch: one contest, two readings ------------------------

  test "[integration] All Contests keeps the plain Settled badge and the guaranteed pool" do
    won = build_contest("two-readings", status: "settled")
    Entry.create!(user: @alex, contest: won, status: "complete", payout_cents: 25_000)
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select "#{ALL} [data-contest-row='#{won.slug}'] [data-contest-badge]", text: "Settled"
    # The POOL, derived from the contest rather than pasted, and explicitly not
    # the $250.00 that the My Contests row reports for the same contest.
    assert_select "#{ALL} [data-contest-row='#{won.slug}'] [data-contest-prize]",
                  text: format("$%.2f", won.guaranteed_prize_dollars)
    assert_select "#{ALL} [data-contest-row='#{won.slug}'] [data-contest-prize]", text: "$250.00", count: 0
    # And in the pool's own colour. A settled row here is not a loss — it is
    # nobody's row — so the grey that means "these prizes went elsewhere" must
    # not leak onto it from the My Contests reading.
    assert_select "#{ALL} [data-contest-row='#{won.slug}'] [data-contest-prize].text-primary", count: 1
    assert_select "#{ALL} [data-contest-row='#{won.slug}'] [data-contest-prize].text-muted", count: 0
  end

  # One viewer's result is not another's. Jordan entered nothing here, so the
  # contest alex won cannot report a win to them anywhere on the page.
  test "[integration] another reader is never told about someone else's win" do
    won = build_contest("not-yours", status: "settled")
    Entry.create!(user: @alex, contest: won, status: "complete", payout_cents: 25_000)
    log_in_as(@jordan)

    get contests_path

    assert_response :success
    assert_select "[data-contest-badge]", text: "Won", count: 0
  end

  # --- Band 3: All Contests, and the controls that act on it -------------

  test "[integration] the Show Settled and New Contest buttons sit with All Contests" do
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select "#{ALL} button[x-text]", count: 1              # Show Settled / Hide Settled
    assert_select "#{ALL} a[href='#{new_contest_path}']", count: 1
    assert_select "#{RAIL} a[href='#{new_contest_path}']", count: 0
  end

  test "[integration] a non-admin gets neither control" do
    log_in_as(@jordan)

    get contests_path

    assert_response :success
    assert_select "a[href='#{new_contest_path}']", count: 0
    assert_select "#{ALL} button[x-text]", count: 0
  end

  # --- Coming soon, end to end through the page --------------------------

  test "[integration] a coming soon contest sorts below the open ones on the rail" do
    soon = build_contest("not-ready-yet", coming_soon: true, created_at: 1.minute.ago)
    open = build_contest("ready-now", created_at: 30.days.ago)

    get contests_path

    assert_response :success
    body = response.body
    assert_operator body.index("data-contest-card=\"#{open.slug}\""),
                    :<,
                    body.index("data-contest-card=\"#{soon.slug}\""),
                    "an open contest must precede a coming-soon one even when the coming-soon one is newer"
  end

  test "[integration] a coming soon contest says so in the All Contests status column too" do
    soon = build_contest("soon-in-the-table", coming_soon: true)

    get contests_path

    assert_response :success
    assert_select "#{ALL} [data-contest-row='#{soon.slug}'] [data-contest-badge]", text: "Coming Soon"
  end
end
