require "test_helper"

require "active_storage/service/disk_service"

# The config/storage.yml half of the QA/production bucket separation guard —
# turf-monster's sibling of the same-named test in mcritchie-industries (where
# the pattern was proven) and mcritchie-studio.
#
# turf-monster-qa boots RAILS_ENV=production, so it loads :amazon (via
# config/environments/production.rb) AND :amazon_public (via
# OgImageAttachable::PUBLIC_OG_SERVICE's Rails.env switch). Both carried the
# hardcoded production bucket; the misresolution was MASKED only by QA holding
# no AWS key. Both are guarded here.
class StorageServiceConfigTest < ActiveSupport::TestCase
  EXPECTED_REGION = "us-east-2".freeze
  PRODUCTION_BUCKET = "turf-monster-production".freeze
  QA_BUCKET = "turf-monster-dev".freeze

  # The two services QA actually resolves on a production-mode boot.
  GUARDED_SERVICES = %i[amazon amazon_public].freeze

  SENTINEL_KEY_ID = "AKIAEXAMPLEONLYTEST".freeze
  SENTINEL_SECRET = "sentinel-secret-never-real".freeze

  # Parsed exactly the way ActiveStorage::Engine parses it, ERB and all.
  def storage_configs
    ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))
  end

  # QA_ENV set EXPLICITLY on every build (nil deletes it) so assertions run on
  # the config, never the operator's shell.
  def build_service(name, qa: false)
    with_env(
      "QA_ENV" => (qa ? "true" : nil),
      "AWS_ACCESS_KEY_ID" => SENTINEL_KEY_ID,
      "AWS_SECRET_ACCESS_KEY" => SENTINEL_SECRET
    ) do
      ActiveStorage::Service::Configurator.build(name, storage_configs)
    end
  end

  def resolved_bucket(name, qa:)
    build_service(name, qa: qa).bucket.name
  end

  def with_env(vars)
    original = vars.keys.index_with { |key| ENV[key] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "the durable services are S3, never a local disk" do
    GUARDED_SERVICES.each do |name|
      service = build_service(name)
      assert_kind_of ActiveStorage::Service::S3Service, service
      refute_kind_of ActiveStorage::Service::DiskService, service,
                     "#{name} must not be a Disk service — Heroku's dyno filesystem is ephemeral"
    end
  end

  # Acceptance #2: production resolution stays byte-identical, per service —
  # the production case is CONSTRUCTED (QA_ENV deleted) and pinned.
  test "each deployed environment targets its own provisioned bucket in us-east-2" do
    GUARDED_SERVICES.each do |name|
      assert_equal PRODUCTION_BUCKET, resolved_bucket(name, qa: false), "#{name} production bucket moved"
      assert_equal QA_BUCKET, resolved_bucket(name, qa: true), "#{name} QA bucket wrong"
      assert_equal EXPECTED_REGION, build_service(name, qa: false).client.client.config.region
    end
  end

  # THE separation guard, asserted as a DIFFERENCE per service (a production
  # literal pin keeps passing after a copy-paste collapses QA onto it), with
  # presence asserted so one nil cannot sail through the inequality.
  test "QA and production resolve DIFFERENT buckets on every guarded service" do
    GUARDED_SERVICES.each do |name|
      production = resolved_bucket(name, qa: false)
      qa = resolved_bucket(name, qa: true)

      assert production.present?, "#{name} must resolve a production bucket"
      assert qa.present?, "#{name} must resolve a QA bucket"
      assert_not_equal production, qa,
                       "turf-monster and turf-monster-qa BOTH boot as RAILS_ENV=production; " \
                       "#{name} resolved #{production.inspect} for both — QA uploads would " \
                       "land in production storage"
    end
  end

  # Fail-safe direction: unset, "", "false", "0", and unrecognised values all
  # resolve PRODUCTION (EnvironmentBanner's allow-list truthiness).
  test "only an allow-listed QA_ENV resolves the dev bucket" do
    [ nil, "", "false", "0", "off", "banana" ].each do |value|
      with_env("QA_ENV" => value,
               "AWS_ACCESS_KEY_ID" => SENTINEL_KEY_ID,
               "AWS_SECRET_ACCESS_KEY" => SENTINEL_SECRET) do
        assert_equal PRODUCTION_BUCKET,
                     ActiveStorage::Service::Configurator.build(:amazon, storage_configs).bucket.name,
                     "QA_ENV=#{value.inspect} must fail safe to production"
      end
    end
  end

  # AppFlags used to carry a third, stricter truthiness for the same flag; it
  # now delegates to the engine. One signal, one allow-list.
  test "AppFlags.qa_environment? shares the engine's truthiness" do
    with_env("QA_ENV" => "1") { assert AppFlags.qa_environment?, "allow-listed '1' must count as QA" }
    with_env("QA_ENV" => "true") { assert AppFlags.qa_environment? }
    with_env("QA_ENV" => nil) { refute AppFlags.qa_environment? }
    with_env("QA_ENV" => "false") { refute AppFlags.qa_environment? }
  end

  # Rendered-config assertion (not the built client): aws-sdk's own credential
  # chain reads ENV directly, so a client from a credential-less config still
  # carries the sentinels — the client-inspecting version guards nothing
  # (measured in the industries sibling).
  test "credentials track ENV, not Rails credentials or a hardcoded literal" do
    GUARDED_SERVICES.each do |name|
      with_env("AWS_ACCESS_KEY_ID" => SENTINEL_KEY_ID, "AWS_SECRET_ACCESS_KEY" => SENTINEL_SECRET) do
        config = storage_configs.fetch(name.to_s)
        assert_equal [ SENTINEL_KEY_ID, SENTINEL_SECRET ],
                     [ config["access_key_id"], config["secret_access_key"] ],
                     "#{name} must read AWS credentials out of ENV"
      end
    end
  end
end
