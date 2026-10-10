require "test_helper"
# Active Storage requires a service's file only when it first builds that
# service, and these tests name the classes directly; requiring them here (the
# public service requires the engine's trash service) keeps every test
# independent of which one ran first.
require "active_storage/service/r2_public_service"

# [unit] Turf Monster's object storage is Cloudflare R2 and nothing else
# (lib/storage_backend.rb + config/storage.yml). Asserted on the service OBJECTS
# Active Storage builds, not on the YAML text, and across the BOOT MATRIX: a bad
# storage config passes Heroku's release phase and then crash-loops web and
# worker, so what each environment does with a missing variable is pinned here.
# No test makes a network call; the credentials are sentinels.
class StorageBackendTest < ActiveSupport::TestCase
  R2_ENDPOINT = "https://sentinel-account.r2.cloudflarestorage.com".freeze
  R2_ENV = {
    "R2_ENDPOINT" => R2_ENDPOINT,
    "R2_ACCESS_KEY_ID" => "r2-sentinel-id",
    "R2_SECRET_ACCESS_KEY" => "r2-sentinel-secret",
    "R2_PUBLIC_URL" => "https://assets.example.test/"
  }.freeze
  # Every variable the storage config reads, cleared: a keyless process.
  KEYLESS = R2_ENV.keys.index_with { nil }.merge(
    "ACTIVE_STORAGE_BACKEND" => nil, "STUDIO_S3_BACKEND" => nil, "QA_ENV" => nil
  ).freeze
  NAMES = %i[amazon amazon_dev amazon_public amazon_public_dev].freeze
  PRODUCTION_BUCKET = "turf-monster-production".freeze
  DEV_BUCKET = "turf-monster-dev".freeze

  # ---- the backend variables ------------------------------------------------

  test "an unset or blank backend variable means r2, and r2 is still accepted" do
    %w[ACTIVE_STORAGE_BACKEND STUDIO_S3_BACKEND].zip(%i[active_storage_stage studio_s3_stage]).each do |name, reader|
      assert_equal "r2", StorageBackend.public_send(reader, {})
      assert_equal "r2", StorageBackend.public_send(reader, { name => " " })
      assert_equal "r2", StorageBackend.public_send(reader, { name => "r2" })
    end
  end

  test "a retired backend value raises a message naming the variable and the fix" do
    %w[s3 mirror_to_r2 mirror_to_s3 R2 disk].each do |retired|
      error = assert_raises(ArgumentError) { StorageBackend.active_storage_stage({ "ACTIVE_STORAGE_BACKEND" => retired }) }
      assert_match(/ACTIVE_STORAGE_BACKEND="#{retired}" is not supported/, error.message)
      assert_match(/Cloudflare R2 only\. Set ACTIVE_STORAGE_BACKEND=r2 or unset it/, error.message)

      error = assert_raises(ArgumentError) { StorageBackend.studio_s3_stage({ "STUDIO_S3_BACKEND" => retired }) }
      assert_match(/STUDIO_S3_BACKEND="#{retired}" is not supported/, error.message)
    end
  end

  test "a retired value fails storage.yml and the Studio::S3 settings in every environment" do
    [ true, false ].each do |production|
      booting(production, R2_ENV.merge("ACTIVE_STORAGE_BACKEND" => "s3")) do
        assert_match(/ACTIVE_STORAGE_BACKEND="s3"/, assert_raises(ArgumentError) { parse }.message)
      end
      booting(production, R2_ENV.merge("STUDIO_S3_BACKEND" => "s3")) do
        assert_match(/STUDIO_S3_BACKEND="s3"/, assert_raises(ArgumentError) { StorageBackend.studio_s3_settings }.message)
      end
    end
  end

  # config/initializers/studio.rb calls verify! while the app boots, so both
  # switches and all four variables are judged before anything is served.
  test "verify! is the boot check: a retired switch or a missing variable raises, a good config passes" do
    booting(true, R2_ENV) { assert StorageBackend.verify! }
    booting(false, {}) { assert StorageBackend.verify! }
    booting(true, R2_ENV.merge("ACTIVE_STORAGE_BACKEND" => "s3")) { assert_raises(ArgumentError) { StorageBackend.verify! } }
    booting(true, R2_ENV.merge("STUDIO_S3_BACKEND" => "mirror_to_r2")) { assert_raises(ArgumentError) { StorageBackend.verify! } }
    booting(true, R2_ENV.merge("R2_ENDPOINT" => nil)) do
      assert_match(/R2_ENDPOINT must be set/, assert_raises(ArgumentError) { StorageBackend.verify! }.message)
    end
    assert_match(/^\s*StorageBackend\.verify!$/, Rails.root.join("config/initializers/studio.rb").read)
  end

  # ---- the boot matrix ------------------------------------------------------

  # Production and QA both boot RAILS_ENV=production. Neither backend variable
  # is set here: the default alone must demand R2, never fall through to S3.
  test "production and QA: each missing R2 variable raises at parse and at Studio.configure, by name" do
    [ nil, "true" ].each do |qa_env|
      StorageBackend::R2_VARIABLES.each do |missing|
        booting(true, R2_ENV.merge("QA_ENV" => qa_env, missing => nil)) do
          error = assert_raises(ArgumentError, "storage.yml must refuse a boot without #{missing}") { parse }
          assert_match(/\A#{missing} must be set/, error.message)

          error = assert_raises(ArgumentError, "Studio.configure must refuse a boot without #{missing}") do
            StorageBackend.studio_s3_settings
          end
          assert_match(/\A#{missing} must be set/, error.message)
        end
      end
    end
  end

  test "production and QA: a blank R2 variable is a missing one" do
    booting(true, R2_ENV.merge("R2_PUBLIC_URL" => "  ")) do
      assert_match(/R2_PUBLIC_URL must be set/, assert_raises(ArgumentError) { parse }.message)
    end
  end

  test "production and QA with nothing set at all raise rather than boot keyless" do
    booting(true, {}) do
      assert_match(/R2_ENDPOINT must be set/, assert_raises(ArgumentError) { parse }.message)
      assert_raises(ArgumentError) { StorageBackend.studio_s3_settings }
    end
  end

  test "production and QA with all four variables load all four services on R2" do
    [ nil, "true" ].each do |qa_env|
      booting(true, R2_ENV.merge("QA_ENV" => qa_env)) do
        assert_equal NAMES.map(&:to_s).sort, (parse.keys.map(&:to_s) - %w[test local]).sort
        assert_equal R2_ENDPOINT, StorageBackend.studio_s3_settings.fetch(:s3_endpoint)
      end
    end
  end

  # Test, CI, and a laptop with no .env.development.
  test "a keyless non-production boot loads storage.yml with Disk services only and raises nothing" do
    booting(false, {}) do
      configs = assert_nothing_raised { parse }
      assert_equal %w[local test], configs.keys.map(&:to_s).sort
      assert configs.values.all? { |config| config["service"] == "Disk" }
      refute StorageBackend.remote_in_development?
    end
  end

  test "a keyless non-production Studio::S3 points at no real store, and never at AWS" do
    booting(false, {}) do
      settings = assert_nothing_raised { StorageBackend.studio_s3_settings }
      assert_equal StorageBackend::UNCONFIGURED_ENDPOINT, settings.fetch(:s3_endpoint)
      assert settings.fetch(:s3_endpoint).end_with?(".invalid"), "a reserved TLD: it can never resolve"
      assert_equal StorageBackend::DEV_PUBLIC_URL, settings.fetch(:s3_public_url)
      # A placeholder pair, so the SDK never walks its default credential chain
      # (~/.aws, then the instance-metadata lookup that hangs on a CI runner).
      assert_equal [ StorageBackend::UNCONFIGURED_KEY ] * 2, settings.values_at(:s3_access_key_id, :s3_secret_access_key)
    end
  end

  # The process this suite runs in is itself the keyless boot (CI sets no R2
  # variable), so read what the real initializer left behind.
  test "this test process booted on that keyless configuration" do
    skip "R2 variables are set in this shell" if StorageBackend.r2_required?
    assert_equal StorageBackend::UNCONFIGURED_ENDPOINT, Studio.s3_endpoint
    assert_equal StorageBackend::UNCONFIGURED_ENDPOINT, Studio::S3.send(:client).config.endpoint.to_s
    assert_equal StorageBackend::UNCONFIGURED_KEY, Studio::S3.send(:client).config.credentials.access_key_id
    refute_match(/amazonaws/, Studio::S3.url(key: "headshots/x.png"))
    assert_equal %i[local test], ActiveStorage::Blob.services.send(:configurations).keys.map(&:to_sym).sort
  end

  test "development with the R2 dev keys uses the remote dev services" do
    booting(false, R2_ENV) do
      assert StorageBackend.remote_in_development?
      assert_equal NAMES.map(&:to_s).sort, (parse.keys.map(&:to_s) - %w[test local]).sort
    end
  end

  test "a half-configured non-production boot raises naming what is missing" do
    booting(false, R2_ENV.merge("R2_SECRET_ACCESS_KEY" => nil)) do
      assert_match(/R2_SECRET_ACCESS_KEY must be set/, assert_raises(ArgumentError) { parse }.message)
      assert_match(/R2_SECRET_ACCESS_KEY must be set/, assert_raises(ArgumentError) { StorageBackend.studio_s3_settings }.message)
    end
  end

  # ---- what the services are ------------------------------------------------

  test "every name is R2 alone: the R2 endpoint, the R2 keys, its own bucket and publicity" do
    expected = { amazon: [ PRODUCTION_BUCKET, false ], amazon_dev: [ DEV_BUCKET, false ],
                 amazon_public: [ PRODUCTION_BUCKET, true ], amazon_public_dev: [ DEV_BUCKET, true ] }
    expected.each do |name, (bucket, is_public)|
      service = build(name)
      assert_equal R2_ENDPOINT, endpoint_of(service), name
      refute_match(/amazonaws/, endpoint_of(service), name)
      assert_equal "r2-sentinel-id", service.client.client.config.credentials.access_key_id, name
      assert_equal "auto", service.client.client.config.region, name
      assert_equal bucket, service.bucket.name, name
      assert_equal is_public, service.public?, name
    end
  end

  test "no service definition names S3, a mirror, or an AWS variable" do
    configs = booting(true, R2_ENV) { parse }
    assert_equal %w[Disk R2Public StudioTrashS3], configs.values.map { |c| c["service"] }.uniq.sort
    assert_empty configs.keys.map(&:to_s).grep(/_s3\z|_r2\z/)
    refute_match(/AWS_|amazonaws|us-east-2/, Rails.root.join("config/storage.yml").read)
  end

  # THE separation guard: turf-monster and turf-monster-qa BOTH boot as
  # RAILS_ENV=production, and only QA_ENV keeps QA's writes out of production.
  test "QA and production resolve DIFFERENT buckets on the services a production boot loads" do
    %i[amazon amazon_public].each do |name|
      production = build(name, "QA_ENV" => nil).bucket.name
      qa = build(name, "QA_ENV" => "true").bucket.name
      assert_equal PRODUCTION_BUCKET, production, name
      assert_equal DEV_BUCKET, qa, name
    end
  end

  # Fail-safe direction: only an allow-listed QA_ENV resolves the dev bucket.
  test "an unrecognised QA_ENV resolves production" do
    [ nil, "", "false", "0", "off", "banana" ].each do |value|
      assert_equal PRODUCTION_BUCKET, build(:amazon, "QA_ENV" => value).bucket.name, "QA_ENV=#{value.inspect}"
    end
  end

  test "the private names are the trash-on-delete service and answer a signed URL" do
    %i[amazon amazon_dev].each do |name|
      assert_instance_of ActiveStorage::Service::StudioTrashS3Service, build(name), name
    end
    url = build(:amazon).url("abc123", expires_in: 300, filename: ActiveStorage::Filename.new("a.png"),
                             content_type: "image/png", disposition: :inline)
    assert_match(%r{\Ahttps://turf-monster-production\.sentinel-account\.r2\.cloudflarestorage\.com/abc123\?.*X-Amz-Signature=}, url)
  end

  test "the public names answer a permanent URL on the public domain and still trash on delete" do
    %i[amazon_public amazon_public_dev].each do |name|
      service = build(name)
      assert_instance_of ActiveStorage::Service::R2PublicService, service
      assert_kind_of ActiveStorage::Service::StudioTrashS3Service, service
      url = service.url("abc123", filename: ActiveStorage::Filename.new("og.png"), content_type: "image/png", disposition: :inline)
      assert_equal "https://assets.example.test/abc123", url
    end
  end

  test "OgImageAttachable.public_service? is true for the public names only" do
    assert OgImageAttachable.public_service?(build(:amazon_public))
    assert OgImageAttachable.public_service?(build(:amazon_public_dev))
    refute OgImageAttachable.public_service?(build(:amazon))
    refute OgImageAttachable.public_service?(ActiveStorage::Blob.services.fetch(:test))
  end

  # R2 has no object ACLs; public read comes from the attached domain alone.
  test "a public service sends no object ACL on upload" do
    %i[amazon_public amazon_public_dev].each { |name| assert_nil build(name).upload_options[:acl], name }
  end

  test "a public service without a public domain refuses to build" do
    error = assert_raises(ArgumentError) do
      ActiveStorage::Service::R2PublicService.new(public_url: " ", bucket: DEV_BUCKET, region: "auto",
                                                  access_key_id: "id", secret_access_key: "secret")
    end
    assert_match(/public_url/, error.message)
  end

  # Active Storage sends Content-MD5 and aws-sdk-s3 >= 1.178 adds a CRC32 by
  # default; R2 refuses a request carrying both (measured 2026-09-28).
  test "every service computes checksums only when required" do
    NAMES.each do |name|
      config = build(name).client.client.config
      assert_equal "when_required", config.request_checksum_calculation, name
      assert_equal "when_required", config.response_checksum_validation, name
    end
  end

  test "studio_s3_settings carries the R2 connection and the public domain" do
    settings = StorageBackend.studio_s3_settings(R2_ENV, production: true)
    assert_equal({ s3_endpoint: R2_ENDPOINT, s3_region: "auto", s3_access_key_id: "r2-sentinel-id",
                   s3_secret_access_key: "r2-sentinel-secret", s3_public_url: "https://assets.example.test/" }, settings)
  end

  private

  def parse = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))

  # Run the block as a boot of the given kind: production (which is also QA) or
  # not, holding exactly the variables given and none of the others.
  def booting(production, vars, &block)
    StorageBackend.stub(:production?, production) { with_env(KEYLESS.merge(vars), &block) }
  end

  def build(name, extra = {})
    booting(true, R2_ENV.merge(extra)) { ActiveStorage::Service::Configurator.build(name, parse) }
  end

  def endpoint_of(service) = service.client.client.config.endpoint.to_s

  def with_env(vars)
    previous = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
