# frozen_string_literal: true

# CARRYING THE 2026-09-04 ROSTER CHANGE TO ROWS THAT ALREADY EXIST.
#
# Editing PARKED_IDENTITIES changes no deployed account. This app has no
# save-time reconciler at all — `ensure_username` runs on CREATE only — so the
# roster describes what a FRESH database gets, and a database with people in it
# keeps whatever it was seeded with. Two of this task's changes therefore reach
# production only if something carries them, and the release phase is
# `bin/rails db:migrate` (see Procfile) plus the `admin:claim_usernames`
# post-deploy, which writes usernames and nothing else.
#
# 1. THE HOUSE ADDRESS. `turf@mcritchie.studio` was a Google GROUP with zero
#    members; the house account is now the real Google user
#    `team@turfmonster.media` (1Password `google.turf.agents`). Left alone, the
#    deployed row keeps the dead address, `User.turf` survives only on its
#    username fallback, and anything selecting the house account BY EMAIL — the
#    contest `#fill` rehearsal helper, for one — quietly stops finding it.
#
# 2. THE RETIRED SEAT. `alex@turfmonster.media` / `alexturf` left the roster
#    because TURF_HOUSE_EMAIL now satisfies the same property. Dropping a row
#    from the roster takes nothing away from it, so it would keep `admin` — on
#    the address printed in the site footer as the support contact, in an app
#    where signing in is a magic link to that mailbox. Demoted, NOT deleted: the
#    row has entries, a purchase and a managed wallet, and destroying a real
#    account is the operator's call.
#
# Both are spelled out here rather than read from `User`. A migration is a
# historical record that must still run years from now against whatever the model
# has become; the constants are live facts that get renamed and deleted.
# `test/models/turf_identity_move_test.rb` asserts the copies agree TODAY, which
# is the only day both exist.
class ReconcileTurfParkedIdentities < ActiveRecord::Migration[8.1]
  OLD_EMAIL = "turf@mcritchie.studio"
  NEW_EMAIL = "team@turfmonster.media"

  RETIRED_ROLES = { "alex@turfmonster.media" => "user" }.freeze
  PRIOR_ROLES = { "alex@turfmonster.media" => "admin" }.freeze

  # Raw SQL, no model: loading `User` here drags in the email-format validation,
  # `ensure_username`, and Sluggable — and a migration that runs years from now
  # must not depend on any of them still behaving as they do today. (The slug is
  # `"#{username}-#{id}"` in this app, so an address change does not stale it.)
  def up
    move(from: OLD_EMAIL, to: NEW_EMAIL)
    reconcile_roles(RETIRED_ROLES)
  end

  def down
    move(from: NEW_EMAIL, to: OLD_EMAIL)
    reconcile_roles(PRIOR_ROLES)
  end

  private

  def move(from:, to:)
    stale = select_one(sanitize("SELECT id FROM users WHERE LOWER(email) = ? LIMIT 1", from))
    return say("no row on #{from} — nothing to move") unless stale

    if select_one(sanitize("SELECT id FROM users WHERE LOWER(email) = ? LIMIT 1", to))
      # BOTH rows exist: someone signed in at the new address before this ran.
      # Merging two accounts is a judgment call with wallets, entries and
      # purchases on both sides, so leave it to the operator rather than guess.
      say "#{to} is already taken; left #{from} in place for a manual merge"
    else
      execute(sanitize("UPDATE users SET email = ?, updated_at = NOW() WHERE id = ?", to, stale["id"]))
      say "#{from} -> #{to}"
    end
  end

  # Guarded on `IS DISTINCT FROM`, so a row already carrying this role is not
  # touched and its `updated_at` does not move. An address with no row is simply
  # not there to update; this never creates one.
  def reconcile_roles(roles)
    roles.each do |email, role|
      changed = update_rows(sanitize(
                              "UPDATE users SET role = ?, updated_at = NOW() " \
                              "WHERE LOWER(email) = ? AND role IS DISTINCT FROM ?",
                              role, email, role
                            ))
      say "#{email} -> #{role}" if changed.positive?
    end
  end

  def sanitize(sql, *binds) = ActiveRecord::Base.sanitize_sql_array([sql, *binds])

  def select_one(sql) = ActiveRecord::Base.connection.select_one(sql)

  # `execute` hands back a driver result; the connection's `update` hands back the
  # affected row count. Named `update_rows` so it cannot shadow what
  # `ActiveRecord::Migration` already delegates under the name `update`.
  def update_rows(sql) = ActiveRecord::Base.connection.update(sql)
end
