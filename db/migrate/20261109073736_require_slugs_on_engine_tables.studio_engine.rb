# This migration comes from studio_engine (originally 20261108160000)
# The engine's own settings and log tables take the first half of the hub's slug
# standard: every slug filled and a unique index on it, on error_logs, theme_settings,
# studio_geo_settings and studio_site_identities (database audit 2026-11-07,
# finding 6). Every host inherits the tables, so one migration reaches them all.
#
# Each table goes through three steps, and a table the host does not have is
# skipped (its own create migration runs first whenever it is installed, since
# install:migrations copies the engine's migrations in order):
#
#   1. Backfill. A NULL or blank slug gets the one its model would write
#      (Sluggable's `name_slug`): `error-log-<id>`, `theme-<app_name>`,
#      `geo-<app_name>`, `site-identity-<app_name>`, with the app name
#      parameterized. A slug another row already holds takes `-<id>` after it.
#   2. Duplicates. A table without a unique slug index (turf-monster's
#      error_logs) may hold a slug twice; every copy after the lowest id takes
#      `-<id>` after it. No table here has slug children, so nothing else
#      references the old value.
#   3. The unique index on `slug` unless one is there. A non-unique slug index
#      is replaced by the unique one.
#
# NOT NULL is deliberately NOT here. The release sweep installs engine
# migrations in the same release as the gem bump, and Heroku runs them while the
# old dynos still serve: the shipped ErrorLog.capture! inserts a NULL slug and
# sets it after, so a NOT NULL would make every error write raise until the
# restart, and again after any `heroku rollback`. The unique index allows many
# NULLs, so old code keeps working. NOT NULL lands in a later engine migration,
# in the release after every host runs the Sluggable ErrorLog this release ships.
#
# Production on 2026-11-08 (every app with a database, read-only counts): no
# NULL or blank slug, no duplicate, so steps 1 and 2 change no row there. The
# largest table is the hub's error_logs at 606 rows, so the index build is
# short. On Postgres each ALTER waits at most LOCK_TIMEOUT
# for its lock; a migrate that cannot get it fails whole, changes nothing, and
# runs again on the next release.
class RequireSlugsOnEngineTables < ActiveRecord::Migration[7.2]
  LOCK_TIMEOUT = "10s"

  # table => the slug prefix its model's name_slug writes before the app name.
  # error_logs has no app name: its slug is the id.
  NAMED = {
    "theme_settings" => "theme",
    "studio_geo_settings" => "geo",
    "studio_site_identities" => "site-identity"
  }.freeze
  TABLES = (["error_logs"] + NAMED.keys).freeze

  def up
    set_lock_timeout
    TABLES.each do |table|
      next unless table_exists?(table) && column_exists?(table, :slug)

      backfill(table)
      dedupe(table)
      unique_slug_index(table)
    end
  end

  # Nothing to undo. The unique index stays: most hosts had it before this
  # migration, and a down cannot tell which index it added. Backfilled slugs
  # stay too; a slug is a valid value either way.
  def down; end

  private

  def set_lock_timeout
    return unless connection.adapter_name.downcase.include?("postgres")

    execute "SET LOCAL lock_timeout = '#{LOCK_TIMEOUT}'"
  end

  def quoted(table) = connection.quote_table_name(table)

  def backfill(table)
    rows = connection.select_rows(<<~SQL.squish)
      SELECT id#{', app_name' if NAMED.key?(table)} FROM #{quoted(table)}
      WHERE slug IS NULL OR slug = '' ORDER BY id
    SQL
    rows.each do |id, app_name|
      derived = derived_slug(table, id, app_name)
      derived = "#{derived}-#{id}" if taken?(table, derived, id)
      write_slug(table, id, derived)
    end
  end

  def derived_slug(table, id, app_name)
    return "error-log-#{id}" unless NAMED.key?(table)

    name = ActiveSupport::Inflector.parameterize(app_name.to_s)
    name.empty? ? "#{NAMED.fetch(table)}-#{id}" : "#{NAMED.fetch(table)}-#{name}"
  end

  def dedupe(table)
    duplicates = connection.select_rows(<<~SQL.squish)
      SELECT id, slug FROM #{quoted(table)} later
      WHERE EXISTS (SELECT 1 FROM #{quoted(table)} earlier WHERE earlier.slug = later.slug AND earlier.id < later.id)
      ORDER BY id
    SQL
    duplicates.each { |id, slug| write_slug(table, id, "#{slug}-#{id}") }
  end

  def taken?(table, slug, id)
    connection.select_value(<<~SQL.squish).present?
      SELECT 1 FROM #{quoted(table)} WHERE slug = #{connection.quote(slug)} AND id <> #{Integer(id)} LIMIT 1
    SQL
  end

  def write_slug(table, id, slug)
    connection.update(<<~SQL.squish, "#{self.class.name} backfill")
      UPDATE #{quoted(table)} SET slug = #{connection.quote(slug)} WHERE id = #{Integer(id)}
    SQL
  end

  def unique_slug_index(table)
    slug_indexes = connection.indexes(table).select { |index| Array(index.columns) == ["slug"] }
    return if slug_indexes.any?(&:unique)

    slug_indexes.each { |index| remove_index table, name: index.name }
    add_index table, :slug, unique: true
  end
end
