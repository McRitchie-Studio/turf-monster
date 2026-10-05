require "test_helper"

# [unit] What the focus card's rail lists, and in what order.
class Live::RailFeedTest < ActiveSupport::TestCase
  setup do
    @game = Game.create!(home_team_slug: "team-a", away_team_slug: "team-b", status: "in_progress",
                         external_id: "777", kickoff_at: 1.hour.ago)
  end

  def play(counter, kind: "play", first_down: false, type: nil, team: "team-b", text: "x")
    GamePlay.create!(game_slug: @game.slug, external_id: "777#{counter}", sequence: counter, kind: kind,
                     first_down: first_down, play_type: type, team_slug: team, text: text)
  end

  def feed = Live::RailFeed.for(@game.reload)

  test "lists first downs, turnovers and scores, and nothing else" do
    play(10)                                   # an ordinary snap
    play(20, first_down: true)
    play(30, kind: "penalty")
    play(40, kind: "turnover", type: "Pass Interception Return")
    play(50, kind: "timeout")
    @game.goals.create!(team_slug: "team-a", points: 7, scoring_type: "touchdown", external_id: "77760")

    assert_equal [["score", "Touchdown", 7], ["turnover", "Interception", nil], ["first_down", "First Down", nil]],
                 feed.map { |item| [item.kind, item.label, item.points] }
  end

  # ESPN's play id orders a goal against the plays around it exactly — even
  # though the goal is written earlier in the cycle than the plays it followed.
  test "a feed-written score sits where its play id puts it" do
    @game.goals.create!(team_slug: "team-b", points: 3, scoring_type: "field_goal", external_id: "77725")
    play(20, first_down: true)
    play(30, first_down: true)

    assert_equal %w[first_down score first_down], feed.map(&:kind)
  end

  # A goal recorded by hand has no play id. It happened after whatever was
  # already on the rail when it was written.
  test "a hand-recorded score sits after the plays that existed when it was written" do
    play(20, first_down: true)
    @game.goals.create!(team_slug: "team-b", points: 6, scoring_type: "touchdown")
    play(30, first_down: true).update_column(:created_at, 1.minute.from_now)

    assert_equal %w[first_down score first_down], feed.map(&:kind)
  end

  test "a turnover is marked for the team that took the ball" do
    play(40, kind: "turnover", type: "Fumble Recovery (Opponent)", team: "team-b")

    item = feed.sole
    assert_equal "Fumble", item.label
    assert_equal "team-a", item.team_slug
  end

  test "names a turnover on downs, and falls back to the plain word" do
    play(40, kind: "turnover", type: "Rush", text: "Turnover on Downs.")
    play(50, kind: "turnover", type: "Something Else")

    assert_equal ["Turnover", "Turnover on Downs"], feed.map(&:label)
  end

  test "keeps the newest twenty" do
    25.times { |index| play(100 + index, first_down: true) }

    assert_equal 20, feed.length
    assert_equal [124, 0, 0], feed.first.order
  end

  test "a scheduled game asks for no plays and still lists a recorded score" do
    @game.update!(status: "scheduled")
    play(20, first_down: true)
    @game.goals.create!(team_slug: "team-b", points: 3, scoring_type: "field_goal")

    assert_equal %w[score], feed.map(&:kind)
  end
end
