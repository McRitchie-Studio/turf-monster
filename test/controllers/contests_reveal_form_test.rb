# frozen_string_literal: true

require "test_helper"

# [integration] The admin edit form carries Contest::Reveal's two controls:
# the reveal time (Denver wall clock) and Hold, and the 24-hour refusal comes
# back as the page's reason rather than a bare 422.
class ContestsRevealFormTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @contest = Contest.new(name: "Reveal Form", slug: "reveal-form", slate: slates(:one), contest_type: "tiny",
                           status: :open, entry_fee_cents: 100, max_entries: 10, user: @admin,
                           starts_at: 10.days.from_now)
    @contest.skip_onchain_callback = true
    @contest.save!
    log_in_as(@admin)
  end

  test "the edit page shows the reveal time and Hold" do
    get edit_contest_path(@contest)

    assert_response :success
    assert_select "input[name='contest[reveal_at_local]'][value='#{@contest.reveal_at_local}']"
    assert_select "input[type=checkbox][name='contest[coming_soon_hold]']"
  end

  test "saving sets the reveal time in Denver and the hold" do
    patch contest_path(@contest), params: { contest: { reveal_at_local: "2026-10-30T09:30", coming_soon_hold: "1" } }

    assert_redirected_to contests_path
    @contest.reload
    assert_equal Time.utc(2026, 10, 30, 15, 30), @contest.reveal_at
    assert @contest.coming_soon_hold?
  end

  test "turning Coming Soon on within 24 hours of the lock is refused with the reason" do
    @contest.update_columns(starts_at: 20.hours.from_now)

    patch contest_path(@contest), params: { contest: { coming_soon: "true" } }

    assert_response :unprocessable_entity
    assert_match "locks within 24 hours", response.body
    refute @contest.reload.coming_soon?
  end

  test "control: with Hold on it saves" do
    @contest.update_columns(starts_at: 20.hours.from_now)

    patch contest_path(@contest), params: { contest: { coming_soon: "true", coming_soon_hold: "1" } }

    assert_redirected_to contests_path
    assert @contest.reload.coming_soon?
  end
end
