require "test_helper"

class ContestsHelperTest < ActionView::TestCase
  include ContestsHelper
  include ApplicationHelper # contest_badge_classes

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

  # --- contest_debug_json_visible? (privacy: the Contest JSON block) ---

  test "contest_debug_json_visible? is false for a guest" do
    stub_current_user(nil)
    assert_equal false, contest_debug_json_visible?
  end

  test "contest_debug_json_visible? is false for a signed-in player" do
    stub_current_user(@other)
    assert_equal false, contest_debug_json_visible?
  end

  test "contest_debug_json_visible? is true for an admin" do
    stub_current_user(@admin)
    assert_equal true, contest_debug_json_visible?
  end

  # While impersonating, current_user is the player and true_user the admin.
  # The predicate reads current_user (require_admin's rule), so the player's
  # page carries no admin payload.
  test "contest_debug_json_visible? is false for an admin impersonating a player" do
    stub_current_user(@other)
    @_true_user = @admin
    assert_equal @admin, true_user
    assert_equal false, contest_debug_json_visible?
  end

  test "contest_debug_json_visible? fails closed when current_user raises" do
    define_singleton_method(:current_user) { raise "no session" }
    assert_equal false, contest_debug_json_visible?
  end

  # --- contest_debug_entries ---

  test "contest_debug_entries serializes no one for a guest or a player" do
    stub_current_user(nil)
    assert_equal [], contest_debug_entries([@entry])
    stub_current_user(@other)
    assert_equal [], contest_debug_entries([@entry])
    stub_current_user(@owner)
    assert_equal [], contest_debug_entries([@entry])
  end

  test "contest_debug_entries strips selections from entries whose picks are hidden" do
    stub_current_user(@admin) # admin, but not on the admin view: open picks stay hidden
    json = contest_debug_entries([@entry])
    assert_equal 1, json.size
    assert_not json[0].key?("selections"), "selections leaked while contest open"
    assert json[0].key?("user"), "user payload should remain for context"
  end

  test "contest_debug_entries includes selections for the admin's own entry" do
    own = @contest.entries.create!(user: @admin, status: :active)
    stub_current_user(@admin)
    json = contest_debug_entries([own])
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

  def true_user
    @_true_user
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

  # The budget is a character PROXY for a pixel constraint whose true value is
  # measured in e2e/quest_chat_prompts.spec.js. This pins the two together: the
  # worst-case names that spec measures must actually be names the budget admits,
  # or the spec is measuring lines the helper would never build.
  #
  # It also records what the number costs. At 10, the 11-13 character names are
  # all countries carrying clean three-letter short_names, and the bracket
  # placeholders are excluded outright.
  LONGEST_BUDGETED_NAMES = ["Commanders", "Buccaneers", "Uzbekistan", "Cape Verde", "Cardinals"].freeze

  test "the e2e width spec measures names the budget actually admits" do
    LONGEST_BUDGETED_NAMES.each do |name|
      assert_operator name.length, :<=, ContestsHelper::CHAT_PROMPT_NAME_BUDGET,
                      "#{name} is in the e2e spec's worst-case list but the budget would replace it"
    end
    # And the spec's list must stay at the TOP of the budget, or it stops being a
    # worst case and the measurement goes slack.
    assert_equal ContestsHelper::CHAT_PROMPT_NAME_BUDGET, LONGEST_BUDGETED_NAMES.map(&:length).max
  end

  test "the name budget drops long country names and bracket placeholders" do
    assert_operator "United States".length, :>, ContestsHelper::CHAT_PROMPT_NAME_BUDGET
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

  # --- contest_spots_left ---
  #
  # Capacity minus the confirmed field, clamped at zero. The subtraction is the
  # whole method, so every case here differs in BOTH operands from the one
  # before it — a stubbed constant would satisfy any single case.

  test "spots left is capacity minus the field" do
    assert_equal 29, @contest.max_entries
    assert_equal 27, contest_spots_left(@contest, 2)
    assert_equal 9, contest_spots_left(@contest, 20)
  end

  test "a full field leaves no spots" do
    assert_equal 0, contest_spots_left(@contest, 29)
  end

  # Comped entries can push a field past its cap (Contest#fill!). "-3 spots
  # left" is not a thing a card may ever say.
  test "an over-filled field clamps to zero rather than going negative" do
    assert_equal 0, contest_spots_left(@contest, 32)
  end

  # A contest with no explicit cap falls back to its FORMAT's, the same pair
  # Contest#fill! and the on-chain payload use.
  test "a contest with no explicit cap uses its format's" do
    @contest.update!(max_entries: nil)

    assert_equal 29, @contest.format_config[:max_entries],
      "the standard format must carry the cap this test reads through"
    assert_equal 24, contest_spots_left(@contest, 5)
  end

  # --- game_day_label ---
  #
  # The multi-week team card labels each opponent column with the day that
  # game is played. kickoff_at is stored in true UTC and this app sets no
  # config.time_zone, so Time.zone IS UTC — these pin the Eastern read that
  # keeps a night game on its own calendar day.

  GameStub = Struct.new(:kickoff_at, keyword_init: true)
  MatchupStub = Struct.new(:game, keyword_init: true)

  test "an afternoon game is labelled with its month and day" do
    # Sun Oct 4 2026, 1:00 PM ET.
    assert_equal "Oct 4", game_day_label(GameStub.new(kickoff_at: Time.utc(2026, 10, 4, 17, 0)))
  end

  test "a night game keeps its Eastern date, not the UTC one it stores as" do
    # Mon Oct 12 2026, 8:15 PM ET — stored as the 13th in UTC.
    game = GameStub.new(kickoff_at: Time.utc(2026, 10, 13, 0, 15))

    assert_equal "Oct 12", game_day_label(game)
    assert_not_equal "Oct 13", game_day_label(game),
                     "the UTC calendar day is the day after this game"
  end

  test "a game that crosses into January dates to the new month" do
    # Sun Jan 3 2027, 1:00 PM ET — week 17 of the 2026 season.
    assert_equal "Jan 3", game_day_label(GameStub.new(kickoff_at: Time.utc(2027, 1, 3, 18, 0)))
  end

  test "no game and no kickoff both label as nil" do
    assert_nil game_day_label(nil)
    assert_nil game_day_label(GameStub.new(kickoff_at: nil))
  end

  # --- opponent_slot_labels ---

  test "a dated column shows the date and details the week" do
    labels = opponent_slot_labels(5, MatchupStub.new(game: GameStub.new(kickoff_at: Time.utc(2026, 10, 13, 0, 15))))

    assert_equal "Oct 12", labels[:shown]
    assert_equal "Week 5 · Oct 12", labels[:detail]
  end

  test "an undated column falls back to the week on both faces" do
    labels = opponent_slot_labels(6, MatchupStub.new(game: nil))

    assert_equal "Week 6", labels[:shown]
    assert_equal "Week 6", labels[:detail]
  end

  test "a bye column has no matchup at all and still names its slot" do
    assert_equal "Week 6", opponent_slot_labels(6, nil)[:shown]
    assert_equal "Week ?", opponent_slot_labels(nil, nil)[:shown]
  end

  # --- a graded contest whose prizes are not paid yet ---

  test "a settlement_pending contest is never badged Won and keeps the pool in its prize cell" do
    @contest.update!(status: "settlement_pending")

    assert_equal "Settlement pending", contest_status_badge(@contest, payout_cents: 300_00)[:label]
    assert_equal "Settlement pending", contest_status_badge(@contest)[:label]
    assert_equal @contest.guaranteed_prize_dollars, contest_prize_cell(@contest, payout_cents: 300_00)[:amount]
    assert_equal :final, contest_live_state(@contest)
    assert picks_visible_for?(@entry), "a graded contest's picks are public"
  end

  test "control: the same contest once settled is badged Won with the amount won" do
    @contest.update!(status: "settled")

    assert_equal "Won", contest_status_badge(@contest, payout_cents: 300_00)[:label]
    assert_equal 300.0, contest_prize_cell(@contest, payout_cents: 300_00)[:amount]
  end
end
