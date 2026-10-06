# Page A/B testing (PageExperiment): a page's named copy variants, the
# per-visitor events that count them (visits and CTA taps), and the variant a
# conversion came from on drop_signups and users.
#
# Schema only. The first experiment (/turf-monster-v2, control vs
# fantasy-football) is DATA, made by `bin/rails experiments:seed_turf_monster_v2`
# (idempotent) or in /admin/experiments, never here.
class CreatePageExperiments < ActiveRecord::Migration[8.1]
  def change
    create_table :page_experiments do |t|
      t.string :slug, null: false
      t.string :name, null: false
      t.string :page_path, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :page_experiments, :slug, unique: true
    # One RUNNING experiment per page: the page asks "which experiment am I in",
    # and two answers would split nobody cleanly.
    add_index :page_experiments, :page_path, unique: true, where: "active",
                                             name: "index_page_experiments_one_active_per_page"

    create_table :page_variants do |t|
      t.string :experiment_slug, null: false
      t.string :key, null: false, limit: 40
      t.string :label
      t.integer :weight, null: false, default: 1
      t.integer :position, null: false, default: 0
      t.text :headline
      t.text :subhead_desktop
      t.text :subhead_mobile
      t.string :meta_title
      t.text :meta_description
      t.timestamps
    end
    add_index :page_variants, %i[experiment_slug key], unique: true

    # One row per visitor per variant per event per day: the ReferralVisit
    # dedupe, so a refresh or a second tap the same day is not a second count.
    create_table :experiment_events do |t|
      t.string :experiment_slug, null: false, limit: 64
      t.string :variant_key, null: false, limit: 40
      t.string :event, null: false, limit: 40
      t.string :visitor_id, null: false, limit: 36
      t.date :occurred_on, null: false
      t.string :reference, limit: 64
      t.datetime :first_seen_at, null: false
    end
    add_index :experiment_events, %i[experiment_slug variant_key event visitor_id occurred_on],
              unique: true, name: "index_experiment_events_dedupe"
    add_index :experiment_events, %i[occurred_on experiment_slug]

    add_column :drop_signups, :experiment_slug, :string, limit: 64
    add_column :drop_signups, :variant_key, :string, limit: 40
    add_index :drop_signups, %i[experiment_slug variant_key]

    add_column :users, :experiment_slug, :string, limit: 64
    add_column :users, :variant_key, :string, limit: 40
    add_index :users, %i[experiment_slug variant_key], where: "experiment_slug IS NOT NULL"
  end
end
