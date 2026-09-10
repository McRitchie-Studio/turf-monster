# The market-snapshot artifact: one row per market:snapshot (or the season-wide
# nfl:expected_team_totals_cache) run. It is the durable historical record of the
# capture process having run — what sport/week it captured, where the numbers came
# from, which seed file it wrote, and how many rows landed by basis. It replaces the
# committed debug PNGs in scripts/data/ as the record of "what ran". See
# docs/workflows/market-snapshot.md step 4.
class CreateMarketSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :market_snapshots do |t|
      t.string :sport, null: false
      t.integer :year, null: false
      # Null when the run spans the whole season (nfl:expected_team_totals_cache);
      # an integer when a single week was captured (market:snapshot WEEK=n).
      t.integer :week
      t.string :source, null: false
      t.string :source_url
      t.datetime :captured_at, null: false
      # Which seed file the run read, and its SHA-256 — so a snapshot pins the exact
      # dataset it ingested even after that file is edited in place.
      t.string :dataset_path, null: false
      t.string :checksum, null: false
      # How much landed, split by basis. row_count == posted_count + derived_count.
      t.integer :row_count, null: false, default: 0
      t.integer :posted_count, null: false, default: 0
      t.integer :derived_count, null: false, default: 0
      t.timestamps
    end

    add_index :market_snapshots, [:sport, :year, :week]
  end
end
