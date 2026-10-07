# This migration comes from studio_engine (originally 20261006120001)
# The engine owns the shape of `error_logs`: ErrorLog and the /error_logs pages
# write and read the columns below on every host.
#
# A host that predates this migration already has the table, built by its own
# migration from docs/NEW_APP_SETUP.md, and the hosts disagree on details (turf
# has NOT NULL on message, an index on created_at and no unique index on slug).
# So the migration is a baseline, not a rebuild:
#
#   - no table: create it in the engine's shape, with its indexes;
#   - a table: add any engine column it lacks, as a plain nullable column, and
#     touch nothing else. No column is changed or dropped, no constraint is
#     tightened and no index is added, because a host's indexes and NOT NULLs
#     are its own, and a unique index built during a release-phase migrate can
#     fail on existing rows or lock a large table.
#
# On every consumer that existed when this shipped, the second branch adds
# nothing. Studio::HostSchema checks the same columns at boot.
class EnsureErrorLogsTable < ActiveRecord::Migration[7.2]
  def up
    unless table_exists?(:error_logs)
      create_table :error_logs do |t|
        t.string :slug
        t.text :message
        t.text :inspect
        t.text :backtrace
        t.string :target_type
        t.bigint :target_id
        t.string :target_name
        t.string :parent_type
        t.bigint :parent_id
        t.string :parent_name

        t.timestamps
      end

      add_index :error_logs, :slug, unique: true
      add_index :error_logs, %i[target_type target_id]
      add_index :error_logs, %i[parent_type parent_id]
      return
    end

    add_column :error_logs, :slug,        :string,   if_not_exists: true
    add_column :error_logs, :message,     :text,     if_not_exists: true
    add_column :error_logs, :inspect,     :text,     if_not_exists: true
    add_column :error_logs, :backtrace,   :text,     if_not_exists: true
    add_column :error_logs, :target_type, :string,   if_not_exists: true
    add_column :error_logs, :target_id,   :bigint,   if_not_exists: true
    add_column :error_logs, :target_name, :string,   if_not_exists: true
    add_column :error_logs, :parent_type, :string,   if_not_exists: true
    add_column :error_logs, :parent_id,   :bigint,   if_not_exists: true
    add_column :error_logs, :parent_name, :string,   if_not_exists: true
    add_column :error_logs, :created_at,  :datetime, if_not_exists: true
    add_column :error_logs, :updated_at,  :datetime, if_not_exists: true
  end

  # The migration records nothing about whether it created the table or found
  # it, so a down cannot tell the engine's table from the host's own, and
  # dropping it would destroy the host's error history. It refuses instead.
  def down
    return unless table_exists?(:error_logs)

    raise ActiveRecord::IrreversibleMigration,
          "EnsureErrorLogsTable cannot tell whether it created error_logs or found the host's own; " \
          "drop the table by hand if this app truly owns none of its rows."
  end
end
