# The play-by-play behind the contest live board's focus game.
#
# Until now the poller kept only SCORING plays (goals), so a reader watching a
# game on the board saw the score move and nothing in between. This holds every
# play ESPN reports: snaps, penalties, timeouts, the two-minute warning.
#
# `external_id` is ESPN's own play id and the unique index on it is what makes
# a polling cycle idempotent, exactly as it does for goals. `sequence` is that
# id with the game's event id taken off the front, which sorts plays in the
# order they happened.
#
# The two timeout columns ride on games because that is where the rest of the
# live situation (down, distance, possession) already lives.
#
# Schema only: no backfill, nothing to run after deploy. Plays arrive with the
# next poll of a game in progress.
class CreateGamePlays < ActiveRecord::Migration[8.1]
  def change
    create_table :game_plays do |t|
      t.string  :game_slug,   null: false
      t.string  :external_id, null: false
      t.bigint  :sequence,    null: false
      t.string  :kind,        null: false, default: "play"
      t.string  :play_type
      t.text    :text
      t.string  :team_slug
      t.integer :period
      t.string  :clock
      t.string  :down_distance
      t.integer :yards
      t.integer :home_score
      t.integer :away_score
      t.timestamps
    end

    add_index :game_plays, :external_id, unique: true
    add_index :game_plays, [:game_slug, :sequence]

    add_column :games, :home_timeouts, :integer
    add_column :games, :away_timeouts, :integer
  end
end
