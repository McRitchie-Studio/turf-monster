require "test_helper"
require Rails.root.join("db/migrate/20261001013400_copy_site_setting_into_site_identity.rb").to_s

# The data migration that carries the retired SiteSetting link-preview defaults
# into Studio::SiteIdentity (/tasks/turf-adopts-link-preview). The SiteSetting
# model is deleted, so the source row is written with SQL, the way production's
# row exists today. The migration is DML only, so it runs inside the test's
# transaction and rolls back with it.
class SiteIdentityCarryTest < ActiveSupport::TestCase
  SOURCE_SLUG = "site-setting".freeze

  setup do
    Studio::SiteIdentity.delete_all
    connection.execute("DELETE FROM site_settings")
  end

  def connection = ActiveRecord::Base.connection

  def migrate(direction)
    capture_io { CopySiteSettingIntoSiteIdentity.new.public_send(direction) }
  end

  def insert_site_setting(title: nil, description: nil)
    now = connection.quote(Time.current)
    # `insert`, not select_value: tests run inside the executor, whose query
    # cache a select_value INSERT would not clear.
    connection.insert(<<~SQL.squish, "SiteSetting Insert", "id")
      INSERT INTO site_settings (slug, default_og_title, default_og_description, created_at, updated_at)
      VALUES (#{connection.quote(SOURCE_SLUG)}, #{connection.quote(title)}, #{connection.quote(description)}, #{now}, #{now})
    SQL
  end

  def attach_site_setting_image(site_setting_id)
    blob = ActiveStorage::Blob.create_and_upload!(io: file_fixture("banner.png").open, filename: "site-og.png",
                                                  content_type: "image/png")
    # SQL, not Attachment.create!: the polymorphic record_type names a class
    # that no longer exists, which is exactly the state production is in.
    connection.execute(<<~SQL.squish)
      INSERT INTO active_storage_attachments (name, record_type, record_id, blob_id, created_at)
      VALUES ('default_og_image', 'SiteSetting', #{site_setting_id}, #{blob.id}, #{connection.quote(Time.current)})
    SQL
    blob
  end

  test "carries the title, description and image into the site identity" do
    id = insert_site_setting(title: "Turf Monster — Skill-Based Pick’em Contests", description: "Generic description.")
    blob = attach_site_setting_image(id)

    migrate(:up)

    row = Studio::SiteIdentity.find_by!(app_name: "Turf Monster")
    assert_equal "Turf Monster — Skill-Based Pick’em Contests", row.title
    assert_equal "Generic description.", row.description
    assert row.image.attached?
    assert_equal blob.id, row.image.blob.id, "the blob is re-pointed, not re-uploaded"
    assert_not ActiveStorage::Attachment.exists?(record_type: "SiteSetting", name: "default_og_image")
    assert row.valid?, row.errors.full_messages.to_sentence
  end

  test "blank source values copy nothing, so the drafted copy answers" do
    insert_site_setting(title: "", description: nil)

    migrate(:up)

    row = Studio::SiteIdentity.find_by!(app_name: "Turf Monster")
    assert_nil row.title
    assert_nil row.description
    assert_not row.image.attached?
    assert_equal Studio.site_title, Studio.site_identity[:title]
  end

  test "never overwrites what the operator already saved" do
    id = insert_site_setting(title: "Old Title", description: "Old description.")
    attach_site_setting_image(id)
    saved = Studio::SiteIdentity.current!
    saved.update!(title: "Operator Title")
    saved.image.attach(io: file_fixture("banner_wide.png").open, filename: "operator.png", content_type: "image/png")

    migrate(:up)

    saved.reload
    assert_equal "Operator Title", saved.title
    assert_equal "Old description.", saved.description, "a blank field is still filled"
    assert_equal "operator.png", saved.image.filename.to_s
  end

  test "is a no-op without a source row, and safe to run twice" do
    migrate(:up)
    assert_equal 0, Studio::SiteIdentity.count

    insert_site_setting(title: "Once")
    migrate(:up)
    migrate(:up)
    assert_equal 1, Studio::SiteIdentity.count
    assert_equal "Once", Studio::SiteIdentity.current.title
  end

  test "down moves the image back to the site setting" do
    id = insert_site_setting(title: "T")
    blob = attach_site_setting_image(id)
    migrate(:up)

    migrate(:down)

    attachment = ActiveStorage::Attachment.find_by(record_type: "SiteSetting", record_id: id, name: "default_og_image")
    assert_equal blob.id, attachment&.blob_id
    assert_not Studio::SiteIdentity.current.image.attached?
  end
end
