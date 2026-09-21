class AddSyncProvenanceToAthletes < ActiveRecord::Migration[8.1]
  def change
    # PROVENANCE, which is what turns a copy into a replica.
    #
    # `synced_at` says when we last pulled this row; `source_updated_at` is the
    # provider's own timestamp for it. Without the second one a consumer cannot
    # tell a row it has up to date from one it merely touched, and cannot build
    # an honest watermark.
    add_column :athletes, :synced_at, :datetime
    add_column :athletes, :source_updated_at, :datetime
    add_index :athletes, :synced_at

    add_column :people, :synced_at, :datetime
    add_column :people, :source_updated_at, :datetime

    # ONE watermark per source, so a partial sync resumes instead of restarting
    # from the beginning of a 2,896-row feed.
    create_table :sync_cursors do |t|
      t.string :source, null: false            # studio_athletes
      t.datetime :watermark_updated_at
      t.bigint :watermark_id
      t.datetime :last_run_at
      t.string :last_status                    # ok | failed | skipped
      t.integer :rows_seen, default: 0
      t.integer :rows_written, default: 0
      t.text :detail
      t.timestamps
    end
    add_index :sync_cursors, :source, unique: true
  end
end
