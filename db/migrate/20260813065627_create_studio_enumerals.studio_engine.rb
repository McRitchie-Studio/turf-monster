# This migration comes from studio_engine (originally 20260623130000)
# Reference migration for the Studio::Enumeral model. Like the engine's
# studio_links / studio_email_deliveries migrations, each consumer app installs
# its own copy of this into db/migrate so the table is created in the app's
# database (the model is shipped by the gem; the table lives per app).
class CreateStudioEnumerals < ActiveRecord::Migration[7.2]
  def change
    create_table :studio_enumerals do |t|
      # `category` groups a fixed set of values (e.g. "pokemon_type"); `key` is
      # the stable machine value within it (e.g. "fire"). label/color/position
      # are presentation; metadata (jsonb) carries any category-specific extras.
      t.string  :category, null: false
      t.string  :key,      null: false
      t.string  :label
      t.string  :color
      t.integer :position, null: false, default: 0
      # A sparse, gappy ordinal (100, 200, …) for a domain ranking distinct from
      # display `position` — e.g. Pokémon types ranked most-common → least-common.
      # The gaps leave room to insert a value between two ranks without
      # renumbering. Nullable: not every enumeral is ranked.
      t.integer :rank
      t.jsonb   :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :studio_enumerals, [:category, :key], unique: true
    add_index :studio_enumerals, [:category, :position]
    add_index :studio_enumerals, [:category, :rank]
  end
end
