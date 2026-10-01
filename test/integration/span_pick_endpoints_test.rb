require "test_helper"

# The two HTTP doors that write a Turf Totals pick, driven with the row a normal
# board never sends: a span team's LATER-week SlateMatchup. See
# test/models/span_pick_guard_test.rb for the model half.
class SpanPickEndpointsTest < ActionDispatch::IntegrationTest
  include SpanContestBuilder

  TEAMS = %w[team-a team-b team-c team-d team-e team-f].freeze

  setup do
    @contest = build_span_contest!(contests(:one))
    @user = users(:sam)
    log_in_as(@user)
  end

  def anchor(team) = span_row(@contest, team, week: 1)
  def later(team)  = span_row(@contest, team, week: 2)

  def toggle(matchup)
    post toggle_selection_contest_path(@contest), params: { matchup_id: matchup.id }, as: :json
  end

  # --- contests#toggle_selection -------------------------------------------

  test "toggle_selection returns 422 for a non-pickable row" do
    assert_no_difference "Selection.count" do
      toggle(later("team-a"))
    end

    assert_response :unprocessable_entity
    assert_match(/not a pickable/i, JSON.parse(response.body)["error"])
  end

  test "toggle_selection returns 422 for the second-week row of a team already picked" do
    toggle(anchor("team-a"))
    assert_response :success

    assert_no_difference "Selection.count" do
      toggle(later("team-a"))
    end

    assert_response :unprocessable_entity
    assert_match(/not a pickable/i, JSON.parse(response.body)["error"])
  end

  test "toggle_selection still accepts a pickable row on a span contest" do
    assert_difference "Selection.count", 1 do
      toggle(anchor("team-a"))
    end

    assert_response :success
    assert_equal({ anchor("team-a").id.to_s => true }, JSON.parse(response.body)["selections"])
  end

  # --- entries#update ------------------------------------------------------

  def active_entry!
    entry = @contest.entries.create!(user: @user, status: :active)
    TEAMS.each { |team| entry.selections.create!(slate_matchup: anchor(team)) }
    entry.reload
  end

  test "entries#update returns 422 for a set carrying a non-pickable row" do
    entry = active_entry!
    before = entry.selections.map(&:slate_matchup_id).sort
    ids = (TEAMS - %w[team-f]).map { |team| anchor(team).id } + [ later("team-a").id ]

    patch contest_entry_path(@contest, entry), params: { matchup_ids: ids }, as: :json

    assert_response :unprocessable_entity
    assert_match(/invalid matchup/i, JSON.parse(response.body)["error"])
    assert_equal before, entry.reload.selections.map(&:slate_matchup_id).sort
  end

  test "entries#update still accepts six pickable rows on a span contest" do
    entry = active_entry!
    ids = TEAMS.map { |team| anchor(team).id }

    patch contest_entry_path(@contest, entry), params: { matchup_ids: ids }, as: :json

    assert_response :success
    assert_equal ids.sort, entry.reload.selections.map(&:slate_matchup_id).sort
  end
end
