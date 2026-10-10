require "test_helper"

# [integration] An og:image uploaded through the amazon_public service reaches a
# landing page's <meta property="og:image"> as a PERMANENT URL on the R2 public
# domain, and purging or replacing an attachment moves its object to trash/
# before deleting it, on the public service and the private one alike. The
# services are the real ones config/storage.yml builds, with the AWS SDK stubbed
# so every request is recorded and none leaves the process.
class OgImageR2StorageTest < ActionDispatch::IntegrationTest
  R2_ENV = {
    "R2_ENDPOINT" => "https://sentinel-account.r2.cloudflarestorage.com",
    "R2_ACCESS_KEY_ID" => "r2-sentinel-id",
    "R2_SECRET_ACCESS_KEY" => "r2-sentinel-secret",
    "R2_PUBLIC_URL" => "https://assets.example.test",
    "ACTIVE_STORAGE_BACKEND" => nil,
    # QA: the production names on the dev bucket, where a non-production process
    # (this one) is allowed to delete.
    "QA_ENV" => "true"
  }.freeze

  setup do
    @original_services = ActiveStorage::Blob.services
    use_r2_services
  end
  teardown { ActiveStorage::Blob.services = @original_services }

  test "the landing page's og:image is a permanent public URL on the R2 public domain" do
    landing_page = landing_pages(:launch)
    blob = upload("amazon_public")
    landing_page.og_image.attach(blob)

    get landing_page_path(landing_page.slug)

    assert_response :success
    og = css_select('meta[property="og:image"]').first&.[]("content")
    assert_equal "https://assets.example.test/#{blob.key}", og
    assert_nil requests("amazon_public").find { |r| r[:operation_name] == :put_object }[:params][:acl],
               "R2 has no object ACLs: the upload must not send one"
  end

  { "amazon_public" => "public", "amazon" => "private" }.each do |service_name, kind|
    test "purging a blob on the #{kind} service trashes its object before deleting it" do
      blob = upload(service_name)
      before = requests(service_name).size

      blob.purge

      sent = requests(service_name).drop(before)
      copy_at = sent.index { |r| r[:operation_name] == :copy_object }
      delete_at = sent.index { |r| r[:operation_name] == :delete_object }
      assert copy_at && delete_at, "expected a copy and a delete, got #{sent.map { |r| r[:operation_name] }}"
      assert_operator copy_at, :<, delete_at, "the trash copy must be sent before the delete"
      assert_equal "turf-monster-dev/#{blob.key}", sent[copy_at][:params][:copy_source]
      assert_match(%r{\Atrash/\d{4}-\d{2}-\d{2}/\d{13}/#{blob.key}\z}, sent[copy_at][:params][:key])
      assert_equal blob.key, sent[delete_at][:params][:key]
      refute ActiveStorage::Blob.exists?(blob.id)
    end
  end

  test "replacing a landing page's og:image trashes the image it replaced" do
    landing_page = landing_pages(:launch)
    first = upload("amazon_public")
    landing_page.og_image.attach(first)

    perform_enqueued_jobs(only: ActiveStorage::PurgeJob) do
      landing_page.og_image.attach(upload("amazon_public"))
    end

    copies = requests("amazon_public").select { |r| r[:operation_name] == :copy_object }
    assert_equal [ "turf-monster-dev/#{first.key}" ], copies.map { |r| r[:params][:copy_source] }
  end

  private

  def upload(service_name)
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new("png"), filename: "og.png",
                                           content_type: "image/png", service_name: service_name)
  end

  def requests(service_name) = ActiveStorage::Blob.services.fetch(service_name.to_sym).client.client.api_requests

  # Rebuild the service registry the way Active Storage does at boot, with every
  # remote service stubbed.
  def use_r2_services
    previous = R2_ENV.keys.to_h { |k| [ k, ENV[k] ] }
    R2_ENV.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    configs = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))
    configs.each_value { |c| c["stub_responses"] = true if c["service"].in?(%w[StudioTrashS3 R2Public]) }
    ActiveStorage::Blob.services = ActiveStorage::Service::Registry.new(configs)
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
