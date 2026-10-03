require "test_helper"

# An NFL contest locks at 11:00 Denver on its opening Sunday (Contest::LockRule),
# so from Thursday Night Football's kickoff until then it is OPEN while two teams
# are already playing. These pin both halves on a production-shaped week:
#
#   * the contest lock — locks_at / locked? / live? / onchain_params, the create
#     default, the API facts, and the pick-visibility rule all read Sunday;
#   * the team lock — every pick writer refuses a team whose game has started.
#
# Production-shaped on purpose: a weekly slate named like the real ones, and Game
# rows with NO season_year or week (real turf rows carry neither; the week lives
# in the slate name). The calendar is Week 4 of 2026: TNF Thursday 2026-10-01
# 18:15 MDT (2026-10-02 00:15Z), the Sunday window 2026-10-04 11:00 MDT (17:00Z).
class ContestNflSundayLockTest < ActiveSupport::TestCase
  TNF     = Time.utc(2026, 10, 2, 0, 15)
  SUNDAY  = Time.utc(2026, 10, 4, 17, 0)
  SNF     = Time.utc(2026, 10, 5, 0, 20)
  FRIDAY  = Time.utc(2026, 10, 2, 18, 0) # between TNF and the Sunday lock

  setup do
    %w[g h].each do |letter|
      Team.find_by(slug: "team-#{letter}") ||
        Team.create!(name: "Team #{letter.upcase}", short_name: "TM#{letter.upcase}", emoji: "\u{1F3F3}")
    end

    @slate = Slate.create!(name: "NFL 2026 Week 4 #{SecureRandom.hex(2)}", week: 4)
    @rows = {}
    { %w[team-a team-b] => TNF, %w[team-c team-d] => SUNDAY,
      %w[team-e team-f] => SUNDAY, %w[team-g team-h] => SNF }.each_with_index do |((home, away), kickoff), index|
      game = Game.create!(home_team_slug: home, away_team_slug: away, kickoff_at: kickoff, status: "scheduled")
      [[home, away], [away, home]].each_with_index do |(team, opponent), side|
        @rows[team] = SlateMatchup.create!(slate: @slate, team_slug: team, opponent_team_slug: opponent,
                                           game_slug: game.slug, rank: index * 2 + side + 1,
                                           turf_score: 1.0, status: "pending")
      end
    end

    travel_to Time.utc(2026, 9, 30, 12, 0) do
      # What every create path stamps: ContestsController#default_start_for_slate.
      @contest = Contest.create!(name: "NFL Wk4 #{SecureRandom.hex(2)}", slate: @slate,
                                 rank: 8000 + rand(900), contest_type: "standard",
                                 user: users(:alex), status: "open", max_entries: 29,
                                 starts_at: ContestsController.new.send(:default_start_for_slate, @slate))
    end
    @user = users(:sam)
  end

  def rows(*teams) = teams.map { |team| @rows.fetch("team-#{team}") }

  # ── The contest lock ────────────────────────────────────────────────────

  test "the create default stamps the Sunday lock, not Thursday's kickoff" do
    assert_equal SUNDAY, @contest.starts_at
    assert_equal SUNDAY, @contest.locks_at
    assert_equal TNF, @contest.first_kickoff_at, "starts (first game) and locks are distinct"
    assert_equal SUNDAY.to_i, @contest.onchain_params[:lock_timestamp]
  end

  test "between TNF and Sunday the contest is open, not locked, not live; at 11:00 Denver it locks" do
    travel_to(FRIDAY) do
      assert_not @contest.locked?
      assert_not @contest.live?
    end
    travel_to(SUNDAY - 1) { assert_not @contest.locked? }
    travel_to(SUNDAY) do
      assert @contest.locked?
      assert @contest.live?
    end
  end

  test "a blank starts_at derives the same Sunday lock, and the API facts agree" do
    @contest.update!(starts_at: nil)

    assert_equal SUNDAY, @contest.locks_at
    assert_equal SUNDAY.to_i, @contest.onchain_params[:lock_timestamp]
    facts = Api::V1::ContestFacts.for(Contest.where(id: @contest.id).includes(:slate).to_a, now: FRIDAY)
    assert_equal SUNDAY, facts.locks_at(@contest)
    assert_not facts.locked?(@contest)
    assert_equal "open", facts.phase(@contest)
  end

  test "an explicit starts_at still wins over the derived lock" do
    custom = Time.utc(2026, 10, 3, 18, 0)
    @contest.update!(starts_at: custom)

    assert_equal custom, @contest.locks_at
    assert_equal custom.to_i, @contest.onchain_params[:lock_timestamp]
  end

  test "a World Cup slate keeps the first-kickoff lock" do
    kickoff = Time.utc(2026, 6, 11, 19, 0)
    game = Game.create!(home_team_slug: "team-b", away_team_slug: "team-a", kickoff_at: kickoff, status: "scheduled")
    slates(:one).slate_matchups.update_all(game_slug: nil)
    slate_matchups(:m1).update!(game_slug: game.slug)
    contest = contests(:one)
    contest.update!(starts_at: nil)

    assert_equal "fifa", contest.slate.sport
    assert_equal kickoff, contest.locks_at
    assert_equal kickoff, ContestsController.new.send(:default_start_for_slate, contest.slate)
  end

  test "picks stay hidden from other players until the Sunday lock, even after TNF kicks off" do
    entry = @contest.entries.create!(user: users(:jordan), status: :active)
    helper = Object.new.extend(ContestsHelper)
    helper.define_singleton_method(:logged_in?) { true }
    viewer = @user
    helper.define_singleton_method(:current_user) { viewer }

    travel_to(FRIDAY) { assert_not helper.picks_visible_for?(entry, @contest) }
    travel_to(SUNDAY) { assert helper.picks_visible_for?(entry, @contest) }
  end

  # ── The team lock, on every pick writer ─────────────────────────────────

  test "toggle_selection! refuses a TNF team and adds a Sunday team" do
    travel_to(FRIDAY) do
      entry = @contest.entries.create!(user: @user, status: :cart)

      error = assert_raises(RuntimeError) { entry.toggle_selection!(@rows["team-a"]) }
      assert_match(/already started/, error.message)

      entry.toggle_selection!(@rows["team-c"])
      assert_equal [@rows["team-c"].id], entry.reload.selections.pluck(:slate_matchup_id)
    end
  end

  test "assert_enterable! (enter / prepare / confirm / managed / agent API) refuses a cart holding a TNF team" do
    travel_to(FRIDAY) do
      cart = @contest.entries.create!(user: @user, status: :cart)
      rows(:a, :c, :d, :e, :f, :g).each { |row| cart.selections.create!(slate_matchup: row) }

      error = assert_raises(Entry::Refusal) { cart.assert_enterable! }
      assert_equal :team_locked, error.code
      assert_raises(Entry::Refusal) { cart.confirm!(comped: true) }
      assert cart.reload.cart?

      clean = @contest.entries.create!(user: users(:casey), status: :cart)
      rows(:c, :d, :e, :f, :g, :h).each { |row| clean.selections.create!(slate_matchup: row) }
      clean.confirm!(comped: true)
      assert clean.reload.active?
    end
  end

  test "update_picks! keeps a TNF team an entry already holds, but never adds or drops one" do
    entry = @contest.entries.create!(user: @user, status: :active)
    rows(:a, :c, :d, :e, :f, :g).each { |row| entry.selections.create!(slate_matchup: row) }

    travel_to(FRIDAY) do
      entry.update_picks!(rows(:a, :c, :d, :e, :f, :h).map(&:id))
      assert_includes entry.reload.selections.pluck(:slate_matchup_id), @rows["team-a"].id, "existing TNF pick untouched"

      error = assert_raises(Entry::Refusal) { entry.update_picks!(rows(:b, :c, :d, :e, :f, :h).map(&:id)) }
      assert_equal :team_locked, error.code
    end
  end

  test "fill! never seeds a TNF team" do
    travel_to(FRIDAY) do
      @contest.fill!(users: [users(:sam), users(:jordan), users(:casey)])

      picked = @contest.entries.confirmed.flat_map { |e| e.selections.map { |s| s.slate_matchup.team_slug } }
      assert_not_empty picked
      assert_empty picked & %w[team-a team-b]
    end
  end

  test "the agent API board marks the TNF teams locked and the rest open" do
    travel_to(FRIDAY) do
      teams = Api::V1::Board.new(@contest, contest_locked: false).teams.to_h { |t| [t[:team][:slug], t[:locked]] }

      assert teams["team-a"]
      assert teams["team-b"]
      assert_not teams["team-c"]
      assert_not teams["team-h"]
    end
  end

  # ── Span slates: the team's FIRST game in the span ──────────────────────

  test "on a span slate a team is unpickable once its first game kicks off, whichever row is pickable" do
    span = Slate.create!(name: "NFL 2026 Weeks 4-5 #{SecureRandom.hex(2)}", week: 4)
    week5 = Time.utc(2026, 10, 11, 17, 0)
    started = Game.create!(home_team_slug: "team-b", away_team_slug: "team-a", kickoff_at: TNF, status: "scheduled")
    tbd = Game.create!(home_team_slug: "team-c", away_team_slug: "team-a", kickoff_at: nil, status: "scheduled")
    later = Game.create!(home_team_slug: "team-d", away_team_slug: "team-c", kickoff_at: week5, status: "scheduled")
    # team-a: week 4 started; its week 5 game has no time yet, so
    # Slate#matchups_by_team sorts that TBD row FIRST and makes it the pickable row.
    tbd_row = SlateMatchup.create!(slate: span, team_slug: "team-a", opponent_team_slug: "team-c", game_slug: tbd.slug,
                                   week: 5, rank: 1, turf_score: 1.0, status: "pending")
    SlateMatchup.create!(slate: span, team_slug: "team-a", opponent_team_slug: "team-b", game_slug: started.slug,
                         week: 4, rank: 1, turf_score: 1.0, status: "pending")
    team_c = SlateMatchup.create!(slate: span, team_slug: "team-c", opponent_team_slug: "team-d", game_slug: later.slug,
                                  week: 5, rank: 2, turf_score: 1.0, status: "pending")
    @contest.update!(slate: span)

    travel_to(FRIDAY) do
      assert_includes @contest.pickable_matchup_ids, tbd_row.id
      assert_not tbd_row.locked?, "the row's own game has no kickoff"
      assert tbd_row.pick_locked?, "but the team's first game in the span has started"
      assert_not team_c.pick_locked?

      entry = @contest.entries.create!(user: @user, status: :cart)
      assert_raises(RuntimeError) { entry.toggle_selection!(tbd_row) }
      assert_equal SUNDAY, span.default_contest_lock_at, "a span locks on its first week's Sunday"
    end
  end
end
