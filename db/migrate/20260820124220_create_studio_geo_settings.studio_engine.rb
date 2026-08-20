# This migration comes from studio_engine (originally 20260818120000)
# The operator's geo choices for ONE app — whether the geo gate is live, which
# countries it refuses, and which subdivisions of which country.
#
# One row per app (Studio.app_name), like theme_settings: an app deploys once,
# and its geo policy is a property of that deployment rather than of a user.
#
# Both lists are jsonb arrays rather than a join table on purpose. They are read
# on EVERY request (the gate runs before the action) and edited by one person a
# few times a year, so the cost that matters is the read — one row, no join — and
# the shape that matters is "the list, as the operator sees it".
class CreateStudioGeoSettings < ActiveRecord::Migration[7.2]
  def change
    # jsonb where it exists, json where it does not. Every app in the ecosystem
    # runs Postgres today, but a migration that can only run on one adapter is a
    # migration a new app can trip over before it has picked a database — and the
    # engine's own test host is sqlite, so this is exercised rather than assumed.
    json_type = connection.adapter_name.to_s.downcase.include?("postgres") ? :jsonb : :json

    create_table :studio_geo_settings do |t|
      t.string  :app_name, null: false

      # The kill switch. Default FALSE: installing the table must not start
      # blocking anybody. An operator turns the gate on from /admin/geo once the
      # lists say what they mean.
      t.boolean :enabled, null: false, default: false

      # ISO 3166-1 alpha-2 codes this app refuses outright — ["CU", "IR"].
      t.column  :banned_countries, json_type, default: []

      # Region TOKENS — ["US-WA", "US-ID"] — never bare subdivision codes. "CA"
      # is California and Canada; the country half is what tells them apart.
      # Studio::GeoSetting normalizes bare input to tokens before writing, so an
      # app migrating a legacy bare list does not have to.
      t.column  :banned_subdivisions, json_type, default: []

      # Sluggable, for the same reason every other Studio settings row has one:
      # the admin surfaces address records by slug, never by sequential id.
      t.string  :slug

      t.timestamps
    end

    add_index :studio_geo_settings, :app_name, unique: true
    add_index :studio_geo_settings, :slug, unique: true
  end
end
