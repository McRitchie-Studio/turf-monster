# Identity backbone for NFL player data, lifted from mcritchie-studio.
#
# Two tables, deliberately split: `people` is the human being (a name that
# survives a trade, a retirement, or a move into coaching), `athletes` is the
# playing profile hanging off it. Coaches and contracts attach to the same
# Person in later phases, which is why the split earns its keep even though
# every Person we seed today is an athlete.
#
# Slug-based FKs throughout, matching the convention teams/games/slates already
# use here — athletes.team_slug references teams.slug, which the nflverse
# importer resolves without a mapping table because both apps already agree on
# the slug vocabulary ("buffalo-bills").
#
# NOTE: this is additive. The existing `players` table stays exactly as it is —
# it carries soccer goal-scorer attribution (goals.player_slug, the admin slate
# manager) and is unrelated to this NFL identity backbone.
class CreatePeopleAndAthletes < ActiveRecord::Migration[8.1]
  def change
    create_table :people do |t|
      t.string :first_name, null: false
      t.string :last_name, null: false
      t.string :slug, null: false
      # Name variants collected as we ingest from sources that disagree about
      # suffixes ("Will Anderson" vs "Will Anderson Jr."). Person.find_by_name
      # falls back to a containment query against this before creating a
      # duplicate record, so it needs the GIN index below.
      t.jsonb :aliases, default: []
      t.boolean :athlete, default: false
      t.boolean :coach, default: false
      t.string :avatar_url
      t.string :location

      t.timestamps
    end

    add_index :people, :slug, unique: true
    add_index :people, [:last_name, :first_name]
    add_index :people, :aliases, using: :gin

    create_table :athletes do |t|
      t.string :slug, null: false
      t.string :person_slug, null: false
      t.string :sport, null: false
      t.string :team_slug
      t.string :position

      t.integer :height_inches
      t.integer :weight_lbs
      t.integer :jersey_number

      t.integer :draft_year
      t.integer :draft_round
      t.integer :draft_pick
      t.string  :college_name

      # Cross-reference IDs. Every downstream importer (PFF grades, Spotrac
      # salaries, ESPN depth charts) matches on one of these rather than on a
      # name, which is what keeps "Will Anderson Jr." from splitting into two
      # records. Unique where present — Postgres allows many NULLs under a
      # unique index, so players missing an ID do not collide with each other.
      t.string  :gsis_id
      t.integer :pff_id
      t.string  :otc_id
      t.string  :espn_id
      t.string  :pfr_id
      t.string  :sleeper_id
      t.string  :nflverse_id

      t.string :espn_headshot_url

      t.timestamps
    end

    add_index :athletes, :slug, unique: true
    add_index :athletes, :person_slug, unique: true
    add_index :athletes, :gsis_id, unique: true
    add_index :athletes, :pff_id, unique: true
    add_index :athletes, :otc_id, unique: true
    add_index :athletes, :pfr_id, unique: true
    add_index :athletes, :sleeper_id, unique: true
    add_index :athletes, :nflverse_id, unique: true
    # espn_id is NOT unique: ESPN reuses ids across sports, and the headshot
    # lookup tolerates a collision where the unique cross-refs would not.
    add_index :athletes, :espn_id
    add_index :athletes, :position
    add_index :athletes, :sport
    add_index :athletes, :team_slug
  end
end
