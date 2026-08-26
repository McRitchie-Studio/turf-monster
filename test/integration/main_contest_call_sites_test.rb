require "test_helper"

# Verifies the three consumers of SeasonConfig.main_contest pick up the
# admin's pointer:
#
#   - GET /  (ContestsController#world_cup) — root redirect
#   - GET /account (AccountsController#show) — the referral card, which resolves
#     its own target through ApplicationHelper#main_contest_target
#   - GET /faucet  (FaucetController#show)   — @contest CTA
class MainContestCallSitesTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    # Wipe contests so we control the fallback chain exactly. Order matters:
    # selections + entries before contests for FK constraints.
    Selection.delete_all
    Entry.delete_all
    Contest.delete_all
    SeasonConfig.set_main_contest!(nil)
  end

  def build_contest(name, status:, created_at: Time.current)
    Contest.create!(
      name: name, status: status, contest_type: "small",
      entry_fee_cents: 1900, max_entries: 5, slate: slates(:one),
      starts_at: 1.week.from_now, rank: 100, created_at: created_at
    )
  end

  # --- Root redirect ---

  test "GET / redirects to the admin-set main contest when present" do
    main  = build_contest("Admin Pick", status: :open, created_at: 5.days.ago)
    newer = build_contest("Newer Open", status: :open, created_at: 1.day.ago)
    SeasonConfig.set_main_contest!(main)

    get root_path
    assert_redirected_to contest_path(main)
    refute_equal contest_path(newer), response.location
  end

  test "GET / falls back to the most-recent open contest when no main is set" do
    older = build_contest("Older Open", status: :open, created_at: 2.days.ago)
    newer = build_contest("Newer Open", status: :open, created_at: 1.day.ago)

    get root_path
    assert_redirected_to contest_path(newer)
  end

  test "GET / still serves a settled contest when no open contest exists" do
    # No open contests; world_cup's extra fallback layer picks any status.
    settled = build_contest("Settled", status: :settled, created_at: 1.day.ago)

    get root_path
    assert_redirected_to contest_path(settled)
  end

  test "GET / redirects to /contests when there are no contests at all" do
    # Already wiped in setup.
    get root_path
    assert_redirected_to contests_path
  end

  # --- /account referral widget ---

  test "GET /account uses SeasonConfig.main_contest for the share widget" do
    main = build_contest("Share Target", status: :open)
    SeasonConfig.set_main_contest!(main)

    log_in_as(@admin)
    get account_path
    assert_response :success
    # The widget renders a tokenized /l invite whose Studio::Link targets the main contest.
    link = Studio::Link.referral_for(@admin, target: "/contests/#{main.slug}")
    assert_includes response.body, "/l/#{link.token}"
  end

  test "GET /account widget falls back to most-recent open when no main is set" do
    older = build_contest("Older Open", status: :open, created_at: 2.days.ago)
    newer = build_contest("Newer Open", status: :open, created_at: 1.day.ago)

    log_in_as(@admin)
    get account_path
    assert_response :success
    link = Studio::Link.referral_for(@admin, target: "/contests/#{newer.slug}")
    assert_includes response.body, "/l/#{link.token}"
  end

  # --- /faucet CTA ---

  test "GET /faucet's CTA targets the main contest when set" do
    main = build_contest("Faucet Target", status: :open, created_at: 5.days.ago)
    older_open = build_contest("Older Open", status: :open, created_at: 10.days.ago)
    SeasonConfig.set_main_contest!(main)

    get faucet_path
    assert_response :success
    # CTA link uses contest_path(@contest) — assert the path appears on the page.
    assert_select "a[href=?]", contest_path(main)
  end
end
