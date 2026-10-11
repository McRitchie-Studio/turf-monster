# This migration comes from studio_engine (originally 20261010120000)
# Adds image_caches.stored_in: where a row's object lives. nil (every existing
# row) and "own" mean this app's own bucket; "production" marks a non-production
# row that REFERENCES production's copy of a seed asset instead of a duplicate
# in the dev bucket (Studio::ImageCache.reference_or_cache!, ImageCache#url).
#
# Nullable with no default, so the add is a catalog-only change on any table
# size and no existing row is rewritten or changes its URL.
#
# image_caches is host-owned; on a host without the table this is a no-op, like
# AllowNullImageCacheOwner. Studio::HostSchema does not require the column: a
# host that has not installed this migration keeps working, and every row reads
# as "own".
class AddStoredInToImageCaches < ActiveRecord::Migration[7.2]
  def up
    return unless table_exists?(:image_caches)

    add_column :image_caches, :stored_in, :string, if_not_exists: true
  end

  def down
    return unless table_exists?(:image_caches)

    remove_column :image_caches, :stored_in, if_exists: true
  end
end
