# This migration comes from studio_engine (originally 20261108170000)
# CHECK users_role_known on the host's `users.role` (database audit 2026-11-07,
# section 3): the database half of Studio::Account's role validation, so a
# mistyped role is refused rather than saved as a quiet non-admin.
#
# THIS IS A MIGRATION AGAINST A HOST TABLE, shipped like the standard profile
# columns (20260813220000): install-copied with
# `bin/rails studio_engine:install:migrations`, never auto-run, and safe on an
# app that already disagrees.
#
#   * No `users` table, no `role` column, or a role that is not a string (an
#     integer enum): skipped.
#   * A CHECK named users_role_known already there: skipped. The hub and Turf
#     installed their own on 2026-11-08, narrowed to viewer + admin, and a host's
#     narrower CHECK is the stronger guard; this one is the ceiling.
#   * A row holding a role outside the list: REFUSED, naming the values, with
#     nothing written. A stray role is a product call (Turf's "user" meant
#     viewer); this migration does not guess it.
#
# Then it fills a NULL role with "viewer" and adds the CHECK.
#
# It sets NO NOT NULL. A dyno still on the old code during a deploy or a
# rollback may insert a user without a role; the column's default ("viewer")
# fills it, and a NULL passes a CHECK, so that write keeps working. NOT NULL is
# a later migration, once every host runs Studio::Account (the same reasoning as
# the engine-tables slug migration, engine-slug-not-null-later). Edited after
# 0.138.0 published it: no app had installed it yet.
#
# The list is SPELLED OUT, not read from Studio::Roles: a migration is a record
# that must still run years from now, and a live constant may move. Widening the
# engine's list is a new migration that replaces this CHECK.
class AddUsersRoleKnownCheck < ActiveRecord::Migration[7.2]
  ROLES = %w[viewer member admin].freeze
  NAME = "users_role_known"

  def up
    return unless string_role?
    return if check_constraint_exists?(:users, name: NAME)

    allowed = ROLES.map { |role| connection.quote(role) }.join(", ")
    unknown = select_values("SELECT DISTINCT role FROM users WHERE role IS NOT NULL AND role NOT IN (#{allowed})")
    if unknown.any?
      raise ActiveRecord::MigrationError, <<~MSG
        AddUsersRoleKnownCheck refused: users.role holds #{unknown.sort.map(&:inspect).join(', ')},
        outside Studio::Roles (#{ROLES.join(', ')}). Move those rows to a known role in a
        migration of this app's own (Turf moved "user" to "viewer"), then run this again.
      MSG
    end

    execute "UPDATE users SET role = 'viewer' WHERE role IS NULL"
    add_check_constraint :users, expression, name: NAME
  end

  # Removes the CHECK only when it is this migration's: one that names every
  # engine role. A host's own users_role_known, which `up` left in place, is
  # narrower (the hub's and Turf's name viewer and admin only) and stays. The
  # NULL roles `up` filled stay "viewer".
  def down
    return unless string_role?

    ours = check_constraints(:users).find { |check| check.name == NAME }
    return unless ours && ROLES.all? { |role| ours.expression.include?("'#{role}'") }

    remove_check_constraint :users, name: NAME
  end

  private

  # On Postgres, the spelling Postgres itself settles on once a schema.rb is
  # loaded (`'x'::character varying::text`), so a host's schema dump after this
  # migrate equals the dump after a load, byte for byte. An `IN (...)` list
  # dumps as `ARRAY[...]::text[]` first and changes on the next load. Anywhere
  # else (the engine's SQLite test host), the plain IN list. The same rule as
  # 20261108160001_add_engine_state_checks.rb.
  def expression
    return "role IN (#{ROLES.map { |role| connection.quote(role) }.join(', ')})" unless postgres?

    array = ROLES.map { |role| "#{connection.quote(role)}::character varying::text" }.join(", ")
    "(role)::text = ANY (ARRAY[#{array}])"
  end

  def postgres? = connection.adapter_name.downcase.include?("postgres")

  def string_role?
    return false unless table_exists?(:users)

    column = columns(:users).find { |c| c.name == "role" }
    column && %i[string text].include?(column.type)
  end
end
