require "test_helper"

# Admin::ScoringController — operator goal-entry console (/admin/scoring).
class Admin::ScoringControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @user  = users(:sam)
  end

  test "index redirects non-admins" do
    log_in_as(@user)
    get admin_scoring_path
    assert_response :redirect
  end

  test "index renders for an admin and lists fixtures that belong to a slate" do
    # Wire a fixture game into a slate matchup so the console has something to list.
    game = games(:past_game)
    slate_matchups(:m1).update!(game_slug: game.slug)

    log_in_as(@admin)
    get admin_scoring_path

    assert_response :success
    assert_select "h2", /Goal Console/
    # The game renders as a game-scorer card carrying its state, with a
    # goal-entry button per side.
    card = css_select('[data-controller="game-scorer"]').sole
    assert_equal game.slug, JSON.parse(card["data-game-scorer-game-value"])["slug"]
    assert_equal %w[home away], card.css('[data-action="game-scorer#addGoal"]').map { |button| button["data-game-scorer-side-param"] }
  end

  test "goal pills resolve team emoji without a per-goal Team query (no N+1)" do
    game = games(:past_game)
    # reload after each create: the first goal's refresh_game_scores saves the
    # game, which regenerates its slug — reload keeps game.slug current.
    3.times { |i| game.goals.create!(team_slug: game.home_team_slug, minute: i + 1); game.reload }
    slate_matchups(:m1).update!(game_slug: game.slug)

    log_in_as(@admin)
    teams_queries = count_teams_queries { get admin_scoring_path }

    assert_response :success
    # The home/away teams load in one eager-load query; goals must NOT add a
    # Team query each (the old goal.team&.emoji path was an N+1).
    assert teams_queries <= 2, "#{teams_queries} teams-table queries with 3 goals — looks like an N+1 on goal.team"
    # And the emoji still renders in the card's game value.
    goals = JSON.parse(css_select('[data-controller="game-scorer"]').sole["data-game-scorer-game-value"])["goals"]
    assert_equal [ game.home_team.emoji ] * 3, goals.map { |goal| goal["teamEmoji"] }
  end

  private

  def count_teams_queries
    count = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      payload = args.last
      count += 1 if payload[:sql] =~ /FROM\s+"teams"/i && !payload[:name].to_s.include?("SCHEMA")
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end
end
