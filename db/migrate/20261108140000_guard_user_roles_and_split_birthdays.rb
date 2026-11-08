# Two fixes to the account primitive (database audit 2026-11-07, P1):
#
# 1. ROLE. `role` takes one list, User::ROLES (viewer, admin), the same as every
#    other Studio app. Turf seeded three rows with a fourth spelling, "user",
#    that nothing reads (Mason, Mack and the retired alex@turfmonster.media);
#    each becomes "viewer", which is what "user" meant here. Then NOT NULL and
#    CHECK users_role_known, so a mistyped role is refused, not saved as a
#    silent non-admin. Measured before writing: production viewer 50 / user 3 /
#    admin 3, no NULL.
#
# 2. BIRTHDAY. Ruling (Alex McRitchie, 2026-11-08): a birthday is stored split,
#    month + day apart from the year, so a record can hold a partial date
#    ("Oct 1, year unknown"). That is the engine's birth_day / birth_month /
#    birth_year trio, which the engine profile page already writes. The age
#    check wrote a whole `date_of_birth` instead (23 production rows; the trio
#    and `birth_date` hold none). This copies each date into the trio where the
#    trio is empty, and adds CHECK users_birthday_valid. The old columns are
#    ignored by the model from this release and dropped in a later one (the
#    14-day deprecation ruling); that drop re-runs this backfill first.
class GuardUserRolesAndSplitBirthdays < ActiveRecord::Migration[8.1]
  BIRTHDAY_CHECK = <<~SQL.squish
    (birth_month IS NULL OR birth_month BETWEEN 1 AND 12)
    AND (birth_day IS NULL OR (birth_month IS NOT NULL AND birth_day BETWEEN 1 AND
      CASE WHEN birth_month = 2 THEN 29 WHEN birth_month IN (4, 6, 9, 11) THEN 30 ELSE 31 END))
    AND (birth_year IS NULL OR birth_year >= 1900)
  SQL

  def up
    execute "UPDATE users SET role = 'viewer' WHERE role IS NULL OR role = 'user'"
    change_column_null :users, :role, false
    add_check_constraint :users, "role IN ('viewer', 'admin')", name: "users_role_known"

    execute <<~SQL.squish
      UPDATE users
      SET birth_year = EXTRACT(YEAR FROM date_of_birth)::integer,
          birth_month = EXTRACT(MONTH FROM date_of_birth)::integer,
          birth_day = EXTRACT(DAY FROM date_of_birth)::integer
      WHERE date_of_birth IS NOT NULL
        AND birth_year IS NULL AND birth_month IS NULL AND birth_day IS NULL
    SQL
    add_check_constraint :users, BIRTHDAY_CHECK, name: "users_birthday_valid"
  end

  # The role rewrite is one-way: which rows held "user" is not recorded, and
  # "viewer" grants the same access. The backfilled trio stays; it is correct.
  def down
    remove_check_constraint :users, name: "users_birthday_valid"
    remove_check_constraint :users, name: "users_role_known"
    change_column_null :users, :role, true
  end
end
