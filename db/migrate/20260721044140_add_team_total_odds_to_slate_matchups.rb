class AddTeamTotalOddsToSlateMatchups < ActiveRecord::Migration[8.1]
  def change
    add_column :slate_matchups, :team_total_over_odds, :integer
    add_column :slate_matchups, :team_total_under_odds, :integer
  end
end
