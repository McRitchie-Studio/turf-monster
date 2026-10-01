# Carries the link-preview defaults the operator set on the retired admin
# dashboard form (SiteSetting, slug "site-setting") into the engine's site
# identity row (Studio::SiteIdentity, app_name "Turf Monster"), which
# /admin/link_preview edits from now on. /tasks/turf-adopts-link-preview.
#
#   site_settings.default_og_title        -> studio_site_identities.title
#   site_settings.default_og_description  -> studio_site_identities.description
#   SiteSetting#default_og_image          -> Studio::SiteIdentity#image
#
# The image is MOVED, not copied: its attachment row is re-pointed at the
# identity row, so the blob (on the public-read service both models name) is
# never re-uploaded and its permanent URL does not change.
#
# Fills only what the identity row has not already set, so a re-run, or an
# operator who reached /admin/link_preview first, is never overwritten. Blank
# source values copy nothing: the drafted config.site_title/site_description
# in config/initializers/studio.rb answer instead, and they carry the same
# words the old hardcoded OgHelper fallbacks did.
#
# The site_settings table is left in place (nothing reads it now); dropping it
# is a follow-up once this has run in production.
class CopySiteSettingIntoSiteIdentity < ActiveRecord::Migration[8.1]
  APP_NAME = "Turf Monster"
  SOURCE_SLUG = "site-setting"
  IDENTITY_SLUG = "site-identity-turf-monster"
  IDENTITY_TYPE = "Studio::SiteIdentity"

  def up
    return unless table_exists?(:site_settings) && table_exists?(:studio_site_identities)

    source = select_one(<<~SQL.squish)
      SELECT id, default_og_title, default_og_description
      FROM site_settings WHERE slug = #{quote(SOURCE_SLUG)}
    SQL
    return if source.nil?

    identity_id = find_or_create_identity_id

    { "title" => source["default_og_title"], "description" => source["default_og_description"] }.each do |column, value|
      next if value.blank?

      execute(<<~SQL.squish)
        UPDATE studio_site_identities SET #{column} = #{quote(value)}, updated_at = #{quote(Time.current)}
        WHERE id = #{identity_id} AND (#{column} IS NULL OR #{column} = '')
      SQL
    end

    move_image(from_type: "SiteSetting", from_id: source["id"], from_name: "default_og_image",
               to_type: IDENTITY_TYPE, to_id: identity_id, to_name: "image")

    bust_identity_cache
  end

  def down
    return unless table_exists?(:site_settings) && table_exists?(:studio_site_identities)

    source_id = select_value("SELECT id FROM site_settings WHERE slug = #{quote(SOURCE_SLUG)}")
    identity_id = select_value("SELECT id FROM studio_site_identities WHERE app_name = #{quote(APP_NAME)}")
    return if source_id.nil? || identity_id.nil?

    # The words stay on both rows (site_settings was never cleared), so only the
    # image needs to go back for the old OgHelper to find it.
    move_image(from_type: IDENTITY_TYPE, from_id: identity_id, from_name: "image",
               to_type: "SiteSetting", to_id: source_id, to_name: "default_og_image")
    bust_identity_cache
  end

  private

  def quote(value)
    connection.quote(value)
  end

  def find_or_create_identity_id
    existing = select_value("SELECT id FROM studio_site_identities WHERE app_name = #{quote(APP_NAME)}")
    return existing if existing

    now = quote(Time.current)
    # `insert` (not select_value with RETURNING) so a query cache, if one is
    # on, is cleared by the write.
    connection.insert(<<~SQL.squish, "SiteIdentity Insert", "id")
      INSERT INTO studio_site_identities (app_name, slug, created_at, updated_at)
      VALUES (#{quote(APP_NAME)}, #{quote(IDENTITY_SLUG)}, #{now}, #{now})
    SQL
  end

  # Re-points the one attachment row, unless the destination already has an
  # image of its own (the operator's newer choice wins).
  def move_image(from_type:, from_id:, from_name:, to_type:, to_id:, to_name:)
    return unless table_exists?(:active_storage_attachments)

    taken = select_value(<<~SQL.squish)
      SELECT 1 FROM active_storage_attachments
      WHERE record_type = #{quote(to_type)} AND record_id = #{to_id} AND name = #{quote(to_name)}
    SQL
    return if taken

    execute(<<~SQL.squish)
      UPDATE active_storage_attachments
      SET record_type = #{quote(to_type)}, record_id = #{to_id}, name = #{quote(to_name)}
      WHERE record_type = #{quote(from_type)} AND record_id = #{from_id} AND name = #{quote(from_name)}
    SQL
  end

  # Studio::SiteIdentity.stored is cached for an hour; a value cached before
  # this ran would hide the copied words until it expired.
  def bust_identity_cache
    Rails.cache.delete("studio/site_identity/v1/#{APP_NAME.parameterize}")
  rescue StandardError
    nil
  end
end
