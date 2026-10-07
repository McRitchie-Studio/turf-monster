# This migration comes from studio_engine (originally 20261006120003)
# The engine owns the shape of `image_caches`: ImageCache, Studio::ImageCache
# and Studio::EmailCatalog write the columns below on every host.
#
# Hosts that cache images already have the table (from their own migration);
# hosts that never did (cyvasse and moms-app when this shipped) get it here, so
# the email banner and logo uploads work on every app.
#
# A baseline, not a rebuild:
#
#   - no table: create it in the engine's shape, with the owner nullable (an
#     app-global image has no owner) and the indexes that back ImageCache's
#     uniqueness validations;
#   - a table: add any engine column it lacks, as a plain nullable column, and
#     touch nothing else. No column is changed or dropped, no constraint is
#     tightened and no index is added.
#
# Studio::HostSchema checks the same columns at boot.
class EnsureImageCachesTable < ActiveRecord::Migration[7.2]
  def up
    unless table_exists?(:image_caches)
      create_table :image_caches do |t|
        t.string :owner_type
        t.bigint :owner_id
        t.string :purpose, null: false
        t.string :variant, null: false
        t.string :s3_key, null: false
        t.string :source_url
        t.string :content_type
        t.integer :bytes

        t.timestamps
      end

      add_index :image_caches, %i[owner_type owner_id], name: "index_image_caches_on_owner"
      add_index :image_caches, :s3_key, unique: true
      add_index :image_caches, %i[owner_type owner_id purpose variant], unique: true,
                name: "idx_image_caches_owner_purpose_variant"
      return
    end

    add_column :image_caches, :owner_type,   :string,   if_not_exists: true
    add_column :image_caches, :owner_id,     :bigint,   if_not_exists: true
    add_column :image_caches, :purpose,      :string,   if_not_exists: true
    add_column :image_caches, :variant,      :string,   if_not_exists: true
    add_column :image_caches, :s3_key,       :string,   if_not_exists: true
    add_column :image_caches, :source_url,   :string,   if_not_exists: true
    add_column :image_caches, :content_type, :string,   if_not_exists: true
    add_column :image_caches, :bytes,        :integer,  if_not_exists: true
    add_column :image_caches, :created_at,   :datetime, if_not_exists: true
    add_column :image_caches, :updated_at,   :datetime, if_not_exists: true
  end

  # The migration records nothing about whether it created the table or found
  # it, so a down cannot tell the engine's table from the host's own cache. It
  # refuses instead.
  def down
    return unless table_exists?(:image_caches)

    raise ActiveRecord::IrreversibleMigration,
          "EnsureImageCachesTable cannot tell whether it created image_caches or found the host's own; " \
          "drop the table by hand if this app truly owns none of its rows."
  end
end
