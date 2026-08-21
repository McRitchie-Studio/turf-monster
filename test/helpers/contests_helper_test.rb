require "test_helper"

class ContestsHelperTest < ActionView::TestCase
  include ContestsHelper

  setup do
    @contest = contests(:one)
    @owner   = users(:sam)
    @other   = users(:jordan)
    @admin   = users(:alex)
    @entry   = @contest.entries.create!(user: @owner, status: :active)
    @admin_view = nil
  end

  # --- picks_visible_for? ---

  test "picks are visible to the entry owner while contest is open" do
    stub_current_user(@owner)
    assert picks_visible_for?(@entry)
  end

  test "picks are hidden from other users while contest is open" do
    stub_current_user(@other)
    assert_not picks_visible_for?(@entry)
  end

  test "picks are hidden from guests while contest is open" do
    stub_current_user(nil)
    assert_not picks_visible_for?(@entry)
  end

  test "picks are visible to admin via /admin URL override" do
    stub_current_user(@admin)
    @admin_view = true
    assert picks_visible_for?(@entry)
  end

  test "admin without @admin_view still respects ownership rules" do
    stub_current_user(@admin)
    @admin_view = nil
    # Admin user, but not on /admin URL → treated like any non-owner.
    assert_not picks_visible_for?(@entry)
  end

  test "picks are visible to everyone once contest is locked" do
    @contest.update!(starts_at: 1.hour.ago) # v0.17: derived lock
    stub_current_user(@other)
    assert picks_visible_for?(@entry)
  end

  test "picks are visible to everyone once contest is settled" do
    @contest.update!(status: "settled")
    stub_current_user(@other)
    assert picks_visible_for?(@entry)
  end

  # --- contest_debug_entries ---

  test "contest_debug_entries strips selections from hidden entries" do
    stub_current_user(@other)
    json = contest_debug_entries([@entry])
    assert_equal 1, json.size
    assert_not json[0].key?("selections"), "selections leaked while contest open"
    assert json[0].key?("user"), "user payload should remain for context"
  end

  test "contest_debug_entries includes selections for the entry owner" do
    stub_current_user(@owner)
    json = contest_debug_entries([@entry])
    assert json[0].key?("selections"), "owner should see their own selections"
  end

  private

  # ActionView::TestCase doesn't run controller callbacks, so we stub the
  # current_user / logged_in? helpers that picks_visible_for? consults.
  def stub_current_user(user)
    @_current_user = user
  end

  def current_user
    @_current_user
  end

  def logged_in?
    @_current_user.present?
  end

  # --- chat_prompt_samples (Quest 2 typewriter deck) ---
  #
  # The deck is what the composer TYPES into its placeholder while the "Send
  # Your First Message" mission is live: two fixed openers, then ONE personal
  # line. The composer rests on the last line, so line three is the one that
  # stays on screen — which is why it has to name a real team and never a blank.

  def pick_teams(entry, *matchups)
    matchups.each { |m| entry.selections.create!(slate_matchup: m) }
    entry
  end

  test "the deck is two fixed openers and one personal line" do
    pick_teams(@entry, slate_matchups(:m1))

    deck = chat_prompt_samples(@contest, @owner)

    assert_equal ContestsHelper::CHAT_PROMPT_LIMIT, deck.length
    assert_equal ["Hey everyone 👋", "Good luck, everyone ⚔️"], deck.first(2)
    assert_equal "A light it up 🏳️", deck.last
  end

  # m1 (rank 1) prices x1.0 and m5 (rank 5) prices x1.6 — the curve pins rank 1
  # at the bottom, so the biggest number is the viewer's biggest swing. Picking
  # the FIRST selection instead of the priciest would name Team A here.
  test "the personal line names the viewer's longest-priced pick" do
    pick_teams(@entry, slate_matchups(:m1), slate_matchups(:m5))

    assert_equal "E light it up 🏳️", chat_prompt_samples(@contest, @owner).last
  end

  test "a player with no picks gets the contest's own longest price" do
    deck = chat_prompt_samples(@contest, @owner)

    assert_equal ContestsHelper::CHAT_PROMPT_LIMIT, deck.length
    # Still a real claim about this contest, not a blank or a dropped line.
    assert_match(/\A\S+ light it up \S+\z/, deck.last)
  end

  # A name longer than the budget would wrap and slice in the 206px mobile
  # composer, and this is the RESTING line, so it is the one that stays broken
  # on screen. Over budget drops to the team's short_name.
  test "a long team name falls back to its short name" do
    team = slate_matchups(:m1).team
    team.update!(mascot: "Bosnia and Herzegovina", short_name: "BIH")
    pick_teams(@entry, slate_matchups(:m1))

    assert_equal "BIH light it up 🏳️", chat_prompt_samples(@contest, @owner).last
  end

  test "a long team name with no short name falls back to the opener" do
    team = slate_matchups(:m1).team
    team.update!(mascot: "Bosnia and Herzegovina", short_name: nil)
    pick_teams(@entry, slate_matchups(:m1))

    assert_equal ContestsHelper::CHAT_PROMPT_NO_TEAM, chat_prompt_samples(@contest, @owner).last
  end

  # The budget is a character proxy for a pixel constraint, so pin the number
  # itself: 14 keeps every real team name (longest: "United States", 13) and
  # drops the World Cup bracket placeholders ("Runner-up Match 101", 19).
  test "the name budget admits real team names and drops bracket placeholders" do
    assert_operator "United States".length, :<=, ContestsHelper::CHAT_PROMPT_NAME_BUDGET
    assert_operator "Runner-up Match 101".length, :>, ContestsHelper::CHAT_PROMPT_NAME_BUDGET
  end

  test "an unpriced slate falls back to an opener rather than a blank" do
    @contest.slate.slate_matchups.update_all(turf_score: nil)

    deck = chat_prompt_samples(@contest.reload, @owner)

    assert_equal ContestsHelper::CHAT_PROMPT_LIMIT, deck.length
    assert_equal ContestsHelper::CHAT_PROMPT_NO_TEAM, deck.last
  end

  test "no line ever carries a blank" do
    pick_teams(@entry, slate_matchups(:m3))

    chat_prompt_samples(@contest, @owner).each do |line|
      assert line.present?, "blank line in the deck"
      # An interpolated nil reads as a double space or a stranded punctuation
      # mark — the tell that a line rendered without its data.
      refute_match(/\s{2}|\s[.…]/, line, "#{line.inspect} looks like it interpolated a nil")
    end
  end

  test "preloaded entries produce the same deck as a cold read" do
    pick_teams(@entry, slate_matchups(:m5))
    preloaded = [@contest.entries.includes(selections: { slate_matchup: :team }).find(@entry.id)]

    assert_equal chat_prompt_samples(@contest, @owner),
                 chat_prompt_samples(@contest, @owner, entries: preloaded)
  end

  test "no viewer and no contest means no deck" do
    assert_empty chat_prompt_samples(@contest, nil)
    assert_empty chat_prompt_samples(nil, @owner)
  end
end
