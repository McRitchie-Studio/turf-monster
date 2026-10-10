require "test_helper"

# [unit] A delete on any R2 service is a MOVE to trash/ first. R2 has no object
# versioning, so the engine's StudioTrashS3 service (and R2Public, which
# inherits it) copies the object to trash/<utc date>/<epoch ms>/<key> before the
# delete is sent; the bucket's expire-trash-3d lifecycle rule ends the grace
# window. The services are the real ones config/storage.yml builds, with the AWS
# SDK stubbed (stub_responses), so every request is recorded and none leaves the
# process.
class StorageTrashTest < ActiveSupport::TestCase
  R2_ENV = {
    "R2_ENDPOINT" => "https://sentinel-account.r2.cloudflarestorage.com",
    "R2_ACCESS_KEY_ID" => "r2-sentinel-id",
    "R2_SECRET_ACCESS_KEY" => "r2-sentinel-secret",
    "R2_PUBLIC_URL" => "https://assets.example.test",
    "ACTIVE_STORAGE_BACKEND" => nil
  }.freeze
  KEY = "abc123def456".freeze

  # name => [QA_ENV, real production?, the bucket it must resolve]
  # One private and one public service for each place a delete can run.
  DELETES = {
    "production, private" => [ :amazon, nil, true, "turf-monster-production" ],
    "production, public" => [ :amazon_public, nil, true, "turf-monster-production" ],
    "QA, private" => [ :amazon, "true", false, "turf-monster-dev" ],
    "QA, public" => [ :amazon_public, "true", false, "turf-monster-dev" ],
    "development, private" => [ :amazon_dev, nil, false, "turf-monster-dev" ],
    "development, public" => [ :amazon_public_dev, nil, false, "turf-monster-dev" ]
  }.freeze

  DELETES.each do |label, (name, qa_env, production, bucket)|
    test "#{label}: delete copies the object under trash/ and only then deletes it" do
      service = build(name, qa_env)
      assert_equal bucket, service.bucket.name

      requests = in_environment(production) { service.delete(KEY) and recorded(service) }

      assert_equal %i[head_object copy_object delete_object], requests.map { |r| r[:operation_name] }
      copy, delete = requests[1][:params], requests[2][:params]
      assert_equal bucket, copy[:bucket]
      assert_equal "#{bucket}/#{KEY}", copy[:copy_source]
      assert_match(%r{\Atrash/\d{4}-\d{2}-\d{2}/\d{13}/#{KEY}\z}, copy[:key])
      assert_equal KEY, copy[:metadata]["original-key"]
      assert_equal({ bucket: bucket, key: KEY }, delete)
    end
  end

  test "a copy that fails raises and the delete is never sent" do
    [ :amazon_dev, :amazon_public_dev ].each do |name|
      service = build(name)
      service.client.client.stub_responses(:copy_object, "InternalError")

      assert_raises(Aws::S3::Errors::InternalError) { service.delete(KEY) }
      assert_equal %i[head_object copy_object], recorded(service).map { |r| r[:operation_name] }, name
    end
  end

  test "an object already gone sends neither a copy nor a delete" do
    service = build(:amazon_dev)
    service.client.client.stub_responses(:head_object, "NotFound")

    assert_nothing_raised { service.delete(KEY) }
    assert_equal %i[head_object], recorded(service).map { |r| r[:operation_name] }
  end

  # The standard: a non-production process never deletes from the production
  # bucket. A laptop or CI resolves `amazon` to turf-monster-production (QA_ENV
  # unset), and the engine's guard refuses before any request is built.
  test "a non-production process is refused a delete on the production bucket, private or public" do
    [ :amazon, :amazon_public ].each do |name|
      service = build(name)
      assert_equal "turf-monster-production", service.bucket.name

      in_environment(false) do
        assert_raises(Studio::S3::Trash::ProductionBucketRefused) { service.delete(KEY) }
        assert_raises(Studio::S3::Trash::ProductionBucketRefused) { service.delete_prefixed("variants/#{KEY}/") }
      end
      assert_empty recorded(service), "#{name}: nothing may reach the production bucket"
    end
  end

  # Variants are regenerable from the original, which is the object trashed.
  test "delete_prefixed stays a hard delete, with no trash copy" do
    service = build(:amazon_dev)
    service.client.client.stub_responses(:list_objects_v2, contents: [ { key: "variants/#{KEY}/a" } ])

    service.delete_prefixed("variants/#{KEY}/")

    assert_equal %i[list_objects_v2 delete_objects], recorded(service).map { |r| r[:operation_name] }
  end

  private

  def build(name, qa_env = nil)
    with_env(R2_ENV.merge("QA_ENV" => qa_env)) do
      configs = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))
      configs.fetch(name.to_s)["stub_responses"] = true
      ActiveStorage::Service::Configurator.build(name, configs)
    end
  end

  def recorded(service) = service.client.client.api_requests

  # Real production, or anything else, as the engine's delete guard reads it.
  def in_environment(production, &block)
    Studio::S3.stub(:production_environment?, production, &block)
  end

  def with_env(vars)
    previous = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
