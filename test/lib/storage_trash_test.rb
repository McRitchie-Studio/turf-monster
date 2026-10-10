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

  # [integration] The same refusal with NOTHING in the engine stubbed: QA_ENV is
  # set in the real ENV and Rails.env reads production, which is exactly how a QA
  # app boots (no QA app sets RAILS_ENV). The engine's own resolution has to read
  # QA_ENV and refuse; only the S3 client is stubbed, so nothing leaves the
  # process. The CONTROL is the same process with QA_ENV unset: real production,
  # and the delete goes through. Without it, a refusal that never consulted
  # QA_ENV (say, one keyed on Rails.env alone) would pass here too.
  test "a QA process, QA_ENV set for real, is refused a production-bucket delete before any request" do
    previous = ENV.fetch("QA_ENV", :unset)

    [ :amazon, :amazon_public ].each do |name|
      service = build(name) # QA_ENV unset at build: the service holds the production bucket
      assert_equal "turf-monster-production", service.bucket.name

      as_rails_production do
        with_env("QA_ENV" => "true") do
          refute Studio::S3.production_environment?, "QA_ENV=true must read as a non-production process"
          assert_raises(Studio::S3::Trash::ProductionBucketRefused) { service.delete(KEY) }
          assert_raises(Studio::S3::Trash::ProductionBucketRefused) { service.delete_prefixed("variants/#{KEY}/") }
        end
        assert_empty recorded(service), "#{name}: a QA process sent a request to the production bucket"

        with_env("QA_ENV" => nil) do
          assert Studio::S3.production_environment?, "control: Rails production without QA_ENV is real production"
          service.delete(KEY)
        end
        assert_equal %i[head_object copy_object delete_object], recorded(service).map { |r| r[:operation_name] }, name
      end
    end

    assert_equal previous, ENV.fetch("QA_ENV", :unset), "QA_ENV must be restored after the test"
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

  # Rails.env as a deployed app reads it. Only the engine's environment check
  # consults it here; the service was built before the block.
  def as_rails_production(&block)
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("production"), &block)
  end

  def with_env(vars)
    previous = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
