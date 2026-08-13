# This migration comes from studio_engine (originally 20260813220000)
# The standard Studio user profile columns — the small set every Studio app
# carries whether or not it uses them today, so an app never has to invent its
# own spelling for the same fact.
#
# THIS IS THE ENGINE'S FIRST MIGRATION AGAINST A HOST TABLE. Every other engine
# migration creates a `studio_*` table the engine owns outright; `users` belongs
# to the host. That boundary is crossed deliberately, on the operator's call
# (2026-08-13), because the alternative is three hand-written migrations in
# mcritchie-studio, turf-monster and mcritchie-industries that must be kept
# identical by discipline alone — and column drift across apps is exactly what a
# standard is supposed to prevent. One definition, one place.
#
# Two properties make that safe:
#
#   1. EVERY add is `if_not_exists: true`. The apps disagree TODAY — McRitchie
#      Studio and turf-monster already have `first_name`, and turf already has
#      `birth_year` (as an integer, matching below). An unguarded add would raise
#      on those apps, which is the failure mode that makes engine migrations
#      against host tables frightening in the first place.
#   2. It no-ops on an app with no `users` table at all, rather than raising.
#      The engine's own dummy is such an app.
#
# Migrations are install-copied (`bin/rails studio_engine:install:migrations`),
# not auto-run, so each app still adopts this deliberately.
#
# ON THE BIRTH COLUMNS: three integers, not one date. Splitting them keeps the
# two questions apps actually ask cheap and separable — age (needs the year, and
# the month/day for the boundary case) and "whose birthday is today" (needs
# month + day, and no year at all). turf-monster's AgePolicy composes a Date from
# the trio. Storing no single date-of-birth column is the point.
#
# ON ip_locations: a jsonb ARRAY of the distinct places an account has signed in
# from, appended to when a NEW location appears. Shape, dedupe and the growth cap
# belong to Studio::IpLocations — the column is just where it lands. It holds
# IP-derived location data, which is personal data in most jurisdictions; the
# 50-entry cap there bounds it, and no app writes to it until it opts in.
class AddStandardUserProfileColumns < ActiveRecord::Migration[7.2]
  def change
    # An app that has no users table (the engine's dummy, and any future
    # consumer that names its accounts something else) is simply skipped.
    return unless table_exists?(:users)

    add_column :users, :first_name, :string, if_not_exists: true

    add_column :users, :birth_day,   :integer, if_not_exists: true
    add_column :users, :birth_month, :integer, if_not_exists: true
    add_column :users, :birth_year,  :integer, if_not_exists: true

    add_column :users, :ip_locations, :jsonb, default: [], null: false, if_not_exists: true
  end
end
