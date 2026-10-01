# This migration comes from studio_engine (originally 20260930120000)
# The SITE IDENTITY for one app: the title, description and image that say what
# the app is. An unfurl (iMessage, Slack, Discord, X...) shows them for any page
# that does not name its own, and Studio.site_identity hands the same copy to any
# other reader. The operator edits them at /admin/link_preview.
#
# One row per app (Studio.app_name), like studio_geo_settings. The IMAGE is not a
# column: it is an Active Storage attachment (Studio::SiteIdentity#image),
# which rides the host's active_storage_* tables.
#
# INSTALLING THIS TABLE TURNS THE ENGINE'S HEAD TAGS ON under the default
# Studio.link_preview_tags = :auto — unless a template under the app's
# app/views writes its own og:title/og:image, in which case :auto stays off
# until the app deletes them (or sets link_preview_tags = true).
class CreateStudioSiteIdentities < ActiveRecord::Migration[7.2]
  def change
    create_table :studio_site_identities do |t|
      t.string :app_name, null: false
      t.string :title
      t.text   :description

      # Sluggable, like every other Studio settings row.
      t.string :slug

      t.timestamps
    end

    add_index :studio_site_identities, :app_name, unique: true
    add_index :studio_site_identities, :slug, unique: true
  end
end
