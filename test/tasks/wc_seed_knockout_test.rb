require "test_helper"
require "rake"

class WcSeedKnockoutTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("wc:seed_knockout")
    @task = Rake::Task["wc:seed_knockout"]
    @task.reenable
    seed_real_knockout_teams!
  end

  test "seeds knockout slates narrowly and idempotently" do
    assert_difference -> { Slate.count }, 6 do
      assert_difference -> { Game.count }, 32 do
        assert_difference -> { SlateMatchup.count }, 64 do
          output = invoke_task
          assert_includes output, "wc:seed_knockout done"
        end
      end
    end

    @task.reenable

    assert_no_difference -> { Team.count } do
      assert_no_difference -> { Slate.count } do
        assert_no_difference -> { Game.count } do
          assert_no_difference -> { SlateMatchup.count } do
            invoke_task
          end
        end
      end
    end

    assert_equal 32, Slate.find_by!(name: "World Cup 2026 Round of 32").slate_matchups.count
  end

  private

  def invoke_task
    capture_io { @task.invoke }.first
  end

  def seed_real_knockout_teams!
    WorldCup2026KnockoutSeed.required_real_team_codes.each do |code|
      Team.find_or_create_by!(short_name: code) do |team|
        team.name = "Team #{code}"
        team.location = "Team #{code}"
        team.emoji = "🏳️"
        team.color_dark = "#111827"
        team.color_light = "#F9FAFB"
        team.sport = "soccer"
        team.league = "fifa"
        team.division = "Test"
        team.rivals = []
      end
    end
  end
end
