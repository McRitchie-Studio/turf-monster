require "test_helper"

# [integration] An og:image uploaded through the staged amazon_public service
# reaches a landing page's <meta property="og:image"> as a PERMANENT URL on every
# stage of the R2 move: the S3 object URL before it, the R2 public domain once R2
# is primary. The services are the real ones config/storage.yml builds for each
# stage, with the AWS SDK stubbed so no request leaves the process.
class OgImageR2StorageTest < ActionDispatch::IntegrationTest
  STAGE_ENV = {
    "R2_ENDPOINT" => "https://sentinel-account.r2.cloudflarestorage.com",
    "R2_ACCESS_KEY_ID" => "r2-sentinel-id",
    "R2_SECRET_ACCESS_KEY" => "r2-sentinel-secret",
    "R2_PUBLIC_URL" => "https://assets.example.test",
    "QA_ENV" => nil
  }.freeze

  setup { @original_services = ActiveStorage::Blob.services }
  teardown { ActiveStorage::Blob.services = @original_services }

  {
    "s3" => %r{\Ahttps://turf-monster-production\.s3\.us-east-2\.amazonaws\.com/},
    "mirror_to_r2" => %r{\Ahttps://turf-monster-production\.s3\.us-east-2\.amazonaws\.com/},
    "mirror_to_s3" => %r{\Ahttps://assets\.example\.test/},
    "r2" => %r{\Ahttps://assets\.example\.test/}
  }.each do |stage, expected|
    test "#{stage}: the landing page's og:image is a permanent public URL on the primary store" do
      use_stage(stage)
      landing_page = landing_pages(:launch)
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("png"), filename: "og.png",
                                                    content_type: "image/png", service_name: "amazon_public")
      landing_page.og_image.attach(blob)

      get landing_page_path(landing_page.slug)

      assert_response :success
      og = css_select('meta[property="og:image"]').first&.[]("content")
      assert_match expected, og
      assert og.end_with?("/#{blob.key}"), "og:image names the blob key directly, not a signed or proxied URL: #{og}"
    end
  end

  private

  # Rebuild the service registry the way Active Storage does at boot, for the
  # given stage, with every remote service stubbed.
  def use_stage(stage)
    previous = STAGE_ENV.keys.to_h { |k| [ k, ENV[k] ] }.merge("ACTIVE_STORAGE_BACKEND" => ENV["ACTIVE_STORAGE_BACKEND"])
    STAGE_ENV.merge("ACTIVE_STORAGE_BACKEND" => stage).each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    configs = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))
    configs.each_value { |c| c["stub_responses"] = true if c["service"].in?(%w[S3 R2Public]) }
    ActiveStorage::Blob.services = ActiveStorage::Service::Registry.new(configs)
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
