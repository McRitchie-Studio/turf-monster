# This migration comes from studio_engine (originally 20261109180000)
# The second half of the engine's slug standard and of the role standard: the
# database refuses a NULL `slug` on error_logs, theme_settings,
# studio_geo_settings and studio_site_identities, and a NULL `role` on the
# host's users (database audit 2026-11-07; the steps
# RequireSlugsOnEngineTables and AddUsersRoleKnownCheck deferred to a later
# release, engine-not-null-next-release).
#
# THE FORM: a validated CHECK named `<table>_<column>_present`, holding
# `<column> IS NOT NULL`, not a column-level NOT NULL.
#
#   * It is the same rule to every write: Postgres refuses the NULL insert or
#     update either way.
#   * It is the one form the release's schema-dump guard
#     (Release::EngineMigrationInstall.schema_dump_safe?) accepts. The sweep
#     migrates each host's throwaway database and diffs db/schema.rb; the guard
#     passes a diff that only ADDS lines. `change_column_null` rewrites the
#     existing `t.string "slug"` line to `t.string "slug", null: false`, a
#     removed line, and the guard refuses it by design. A CHECK adds one
#     `t.check_constraint` line and removes nothing.
#   * Its dump is stable. Postgres deparses `slug IS NOT NULL` to
#     `(slug IS NOT NULL)` and deparses that to itself again, so a host's dump
#     after this migrate equals its dump after a schema load, byte for byte
#     (unlike an `IN (...)` list, see AddUsersRoleKnownCheck#expression).
#   * On Postgres 12 and later, a validated `CHECK (x IS NOT NULL)` lets a
#     later `SET NOT NULL` skip its table scan, if that form is ever wanted.
#
# ROLLBACK SAFETY. A column that is NOT NULL breaks every insert that leaves it
# NULL, and Heroku runs this migration while the previous release's dynos still
# serve, and a `heroku rollback` keeps the constraint. So this migration ships
# only once every host already runs code that never writes a NULL here:
#
#   * error_logs: ErrorLog includes Sluggable from 0.138.0 (first shipped in
#     0.141.0), which writes a placeholder slug before the insert. Up to 0.137.0,
#     ErrorLog.capture! inserted a NULL slug and filled it after.
#   * theme_settings, studio_geo_settings, studio_site_identities: Sluggable
#     since 0.129.0.
#   * users.role: the column's default is "viewer" on every host, and no engine
#     or host code writes an explicit NULL role.
#
# The error_logs line is the floor: a host must have run 0.141.0 or later in
# production for one release before it installs this migration. A host that
# jumps from 0.137.0 or older straight to this version in one release breaks
# its own error writes while the old dynos drain, and again on a rollback.
#
# Each step, per table, and a table or column the host does not have is skipped:
#
#   1. A column that is already NOT NULL (the hub's and Turf's users.role) needs
#      no CHECK: skipped.
#   2. A CHECK of this name already there: skipped, so a second run is a no-op.
#   3. Backfill. A NULL or blank slug gets the one its model would write (the
#      same rule as RequireSlugsOnEngineTables, copied, since a migration must
#      not depend on another migration's class); a NULL role becomes "viewer".
#   4. Add the CHECK, validated.
#
# Production on 2026-11-08 held no NULL slug and no NULL role. On Postgres each
# ALTER waits at most LOCK_TIMEOUT for its lock; a migrate that cannot get it
# fails whole, changes nothing, and runs again on the next release.
class AddEngineNotNullChecks < ActiveRecord::Migration[7.2]
  LOCK_TIMEOUT = "10s"

  # table => the slug prefix its model's name_slug writes before the app name.
  # error_logs has no app name: its slug is the id.
  NAMED = {
    "theme_settings" => "theme",
    "studio_geo_settings" => "geo",
    "studio_site_identities" => "site-identity"
  }.freeze
  SLUG_TABLES = ([ "error_logs" ] + NAMED.keys).freeze

  # [table, column] pairs, in the order `up` runs them.
  COLUMNS = (SLUG_TABLES.map { |table| [ table, "slug" ] } + [ %w[users role] ]).freeze

  def self.constraint_name(table, column) = "#{table}_#{column}_present"

  def up
    set_lock_timeout
    COLUMNS.each do |table, column|
      next unless nullable_column?(table, column)

      name = self.class.constraint_name(table, column)
      next if check_constraint_exists?(table, name: name)

      column == "role" ? backfill_role : backfill_slug(table)
      add_check_constraint table, "#{column} IS NOT NULL", name: name
    end
  end

  # Removes only the CHECKs `up` adds. Backfilled values stay: they are valid
  # either way. Run it before a rollback to a release older than 0.141.0 (see
  # the changelog): that code inserts a NULL error_logs slug.
  def down
    COLUMNS.each do |table, column|
      next unless table_exists?(table)

      remove_check_constraint table, name: self.class.constraint_name(table, column), if_exists: true
    end
  end

  private

  def postgres? = connection.adapter_name.downcase.include?("postgres")

  def set_lock_timeout
    return unless postgres?

    execute "SET LOCAL lock_timeout = '#{LOCK_TIMEOUT}'"
  end

  def nullable_column?(table, column)
    return false unless table_exists?(table)

    found = columns(table).find { |c| c.name == column }
    found.present? && found.null
  end

  def quoted(table) = connection.quote_table_name(table)

  def backfill_role
    execute "UPDATE users SET role = 'viewer' WHERE role IS NULL"
  end

  def backfill_slug(table)
    rows = connection.select_rows(<<~SQL.squish)
      SELECT id#{', app_name' if NAMED.key?(table)} FROM #{quoted(table)}
      WHERE slug IS NULL OR slug = '' ORDER BY id
    SQL
    rows.each do |id, app_name|
      derived = derived_slug(table, id, app_name)
      derived = "#{derived}-#{id}" if taken?(table, derived, id)
      connection.update(<<~SQL.squish, "#{self.class.name} backfill")
        UPDATE #{quoted(table)} SET slug = #{connection.quote(derived)} WHERE id = #{Integer(id)}
      SQL
    end
  end

  def derived_slug(table, id, app_name)
    return "error-log-#{id}" unless NAMED.key?(table)

    name = ActiveSupport::Inflector.parameterize(app_name.to_s)
    name.empty? ? "#{NAMED.fetch(table)}-#{id}" : "#{NAMED.fetch(table)}-#{name}"
  end

  def taken?(table, slug, id)
    connection.select_value(<<~SQL.squish).present?
      SELECT 1 FROM #{quoted(table)} WHERE slug = #{connection.quote(slug)} AND id <> #{Integer(id)} LIMIT 1
    SQL
  end
end
