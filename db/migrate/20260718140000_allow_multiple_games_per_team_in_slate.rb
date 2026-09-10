class AllowMultipleGamesPerTeamInSlate < ActiveRecord::Migration[7.2]
  # A Slate is a POOL OF GAMES, not one NFL week. A team appears once per game it
  # plays in the slate, and its expected points is the SUM across those games.
  #
  # The old unique index on [slate_id, team_slug] is precisely what forbade that:
  # it allowed a team to appear at most once per slate, so a "Weeks 1-3" slate
  # could not hold the same 32 teams three times.
  #
  # NOTE on the NULL caveat: game_slug is nullable (bracket placeholders carry no
  # game yet) and this is PG 14, which predates NULLS NOT DISTINCT — so rows with
  # a NULL game_slug are all mutually distinct to this index and could duplicate.
  # SlateMatchup carries a matching model-level uniqueness validation, which
  # generates `game_slug IS NULL` and DOES catch that case on the app path.
  def up
    remove_index :slate_matchups, column: [:slate_id, :team_slug]
    add_index :slate_matchups, [:slate_id, :team_slug, :game_slug],
              unique: true, name: "index_slate_matchups_on_slate_team_and_game"
  end

  def down
    remove_index :slate_matchups, name: "index_slate_matchups_on_slate_team_and_game"
    add_index :slate_matchups, [:slate_id, :team_slug], unique: true
  end
end
