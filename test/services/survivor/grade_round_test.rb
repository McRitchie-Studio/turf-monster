require "test_helper"

class Survivor::GradeRoundTest < ActiveSupport::TestCase
  setup do
    @user  = User.first
    @alpha = make_team("wcstest-alpha")
    @bravo = make_team("wcstest-bravo")
    @gamma = make_team("wcstest-gamma")
    @delta = make_team("wcstest-delta")

    @contest = Contest.create!(
      name:            "WCS Test #{SecureRandom.hex(3)}",
      game_type:       "world_cup_survivor",
      contest_type:    "survivor_wc_free",
      entry_fee_cents: 0,
      max_entries:     59,
      status:          "open"
    )
    @round = SurvivorRound.create!(number: 1, name: "Test Matchday", stage: "group", status: "upcoming")
  end

  test "group stage: a win and a draw survive, a loss is eliminated" do
    make_game(@alpha, @bravo, home_score: 2, away_score: 0, status: "completed")
    make_game(@gamma, @delta, home_score: 1, away_score: 1, status: "completed")

    won  = entry_picking(@alpha)
    lost = entry_picking(@bravo)
    drew = entry_picking(@gamma)

    Survivor::GradeRound.call(@round)

    assert won.reload.alive?,        "a winning pick should survive"
    assert drew.reload.alive?,       "a drawn pick should survive"
    assert lost.reload.eliminated?,  "a losing pick should be eliminated"
    assert_equal 1, lost.eliminated_round
    assert_equal "survived",   won.pick_for(@round).result
    assert_equal "eliminated", lost.pick_for(@round).result
    assert_equal "completed",  @round.reload.status
    assert_equal 1, won.reload.score
    assert_equal 0, lost.reload.score
  end

  test "a missed pick eliminates the entry" do
    make_game(@alpha, @bravo, home_score: 1, away_score: 0, status: "completed")
    skipped = Entry.create!(user: @user, contest: @contest, status: "active")

    Survivor::GradeRound.call(@round)

    assert skipped.reload.eliminated?
    assert_equal 1, skipped.eliminated_round
  end

  test "knockout stage: only the advancing team survives" do
    ko = SurvivorRound.create!(number: 2, name: "Test Knockout", stage: "knockout", status: "upcoming")
    make_game(@alpha, @bravo, round: ko, home_score: 0, away_score: 0,
              status: "completed", advancing: @alpha.slug)

    advanced = entry_picking(@alpha, round: ko)
    knocked  = entry_picking(@bravo, round: ko)

    Survivor::GradeRound.call(ko)

    assert advanced.reload.alive?,     "the advancing team should survive"
    assert knocked.reload.eliminated?, "the knocked-out team should be eliminated"
  end

  test "refuses to grade a round whose games are not complete" do
    make_game(@alpha, @bravo, status: "scheduled")
    assert_raises(RuntimeError) { Survivor::GradeRound.call(@round) }
  end

  test "finalize: co-survivors split the guaranteed prize via Contest#grade!" do
    make_game(@alpha, @bravo, home_score: 3, away_score: 1, status: "completed")
    s1  = entry_picking(@alpha)
    s2  = entry_picking(@alpha)
    out = entry_picking(@bravo)

    Survivor::GradeRound.call(@round)
    @contest.grade!

    assert_equal "settled", @contest.reload.status
    assert_equal 1, s1.reload.rank
    assert_equal 1, s2.reload.rank
    # Free-roll prize is $200, split evenly between the two survivors.
    assert_equal 100_00, s1.payout_cents
    assert_equal 100_00, s2.payout_cents
    assert_equal 0, out.reload.payout_cents
  end

  private

  def make_team(slug)
    Team.create!(slug: slug, name: slug.titleize, short_name: slug[-3..].upcase,
                 location: slug.titleize, emoji: "🏳️",
                 color_dark: "#111111", color_light: "#222222")
  end

  def make_game(home, away, round: @round, home_score: nil, away_score: nil,
                status: "scheduled", advancing: nil)
    Game.create!(home_team_slug: home.slug, away_team_slug: away.slug, survivor_round: round,
                 home_score: home_score, away_score: away_score,
                 status: status, advancing_team_slug: advancing)
  end

  def entry_picking(team, round: @round)
    entry = Entry.create!(user: @user, contest: @contest, status: "active")
    SurvivorPick.create!(entry: entry, survivor_round: round, team_slug: team.slug)
    entry
  end
end
