require "test_helper"

# [unit] The switch that moves Turf Monster's Active Storage off AWS S3 onto
# Cloudflare R2 (lib/storage_backend.rb + config/storage.yml), asserted on the
# service OBJECTS Active Storage builds, not on the YAML text: a stage that
# renders but resolves to the wrong store, a mirror pointed the wrong way, or a
# public service that answers a signed URL fails here instead of on the first
# upload after a flip. No test makes a network call; the credentials are sentinels.
class StorageBackendTest < ActiveSupport::TestCase
  R2_ENDPOINT = "https://sentinel-account.r2.cloudflarestorage.com".freeze
  R2_ENV = {
    "R2_ENDPOINT" => R2_ENDPOINT,
    "R2_ACCESS_KEY_ID" => "r2-sentinel-id",
    "R2_SECRET_ACCESS_KEY" => "r2-sentinel-secret",
    "R2_PUBLIC_URL" => "https://assets.example.test/",
    "AWS_ACCESS_KEY_ID" => "AKIAEXAMPLEONLYTEST",
    "AWS_SECRET_ACCESS_KEY" => "aws-sentinel-secret",
    "QA_ENV" => nil
  }.freeze
  NAMES = %i[amazon amazon_dev amazon_public amazon_public_dev].freeze

  test "unset and blank read as the S3 stage; an unknown stage raises" do
    assert_equal "s3", StorageBackend.active_storage_stage({})
    assert_equal "s3", StorageBackend.active_storage_stage({ "ACTIVE_STORAGE_BACKEND" => " " })
    assert_raises(ArgumentError) { StorageBackend.active_storage_stage({ "ACTIVE_STORAGE_BACKEND" => "R2" }) }
  end

  test "s3 stage: all four names are the AWS services they were, same buckets and publicity" do
    expected = { amazon: [ "turf-monster-production", false ], amazon_dev: [ "turf-monster-dev", false ],
                 amazon_public: [ "turf-monster-production", true ], amazon_public_dev: [ "turf-monster-dev", true ] }
    expected.each do |name, (bucket, is_public)|
      service = build(name, "s3")
      assert_instance_of ActiveStorage::Service::S3Service, service, name
      assert_match(/amazonaws\.com/, endpoint_of(service), name)
      assert_equal bucket, service.bucket.name, name
      assert_equal is_public, service.public?, name
    end
  end

  test "the S3 stage needs no R2 variable at all" do
    with_env(R2_ENV.merge("ACTIVE_STORAGE_BACKEND" => nil, "R2_ENDPOINT" => nil, "R2_PUBLIC_URL" => nil)) do
      assert_nothing_raised { parse }
    end
  end

  test "QA_ENV points the production names at the dev bucket on both stores" do
    %w[s3 r2].each do |stage|
      assert_equal "turf-monster-dev", build(:amazon, stage, "QA_ENV" => "true").bucket.name
      assert_equal "turf-monster-dev", build(:amazon_public, stage, "QA_ENV" => "true").bucket.name
    end
  end

  test "mirror_to_r2: S3 is primary and R2 receives every write, for every name" do
    NAMES.each do |name|
      service = build(name, "mirror_to_r2")
      assert_instance_of ActiveStorage::Service::MirrorService, service, name
      assert_match(/amazonaws\.com/, endpoint_of(service.primary), name)
      assert_equal [ R2_ENDPOINT ], service.mirrors.map { |m| endpoint_of(m) }, name
    end
  end

  test "mirror_to_s3: R2 is primary and S3 still receives every write, for every name" do
    NAMES.each do |name|
      service = build(name, "mirror_to_s3")
      assert_equal R2_ENDPOINT, endpoint_of(service.primary), name
      assert_match(/amazonaws\.com/, endpoint_of(service.mirrors.first), name)
    end
  end

  test "r2 stage: every name is R2 alone, same bucket name, R2 keys" do
    NAMES.each do |name|
      service = build(name, "r2")
      assert_equal R2_ENDPOINT, endpoint_of(service), name
      assert_equal build(name, "s3").bucket.name, service.bucket.name, name
      assert_equal "r2-sentinel-id", service.client.client.config.credentials.access_key_id, name
    end
  end

  test "the public names on R2 answer a permanent URL on the public domain, the private ones a signed URL" do
    %i[amazon_public amazon_public_dev].each do |name|
      service = build(name, "r2")
      assert_instance_of ActiveStorage::Service::R2PublicService, service
      url = service.url("abc123", filename: ActiveStorage::Filename.new("og.png"), content_type: "image/png", disposition: :inline)
      assert_equal "https://assets.example.test/abc123", url
    end

    private_url = build(:amazon, "r2").url("abc123", expires_in: 300, filename: ActiveStorage::Filename.new("a.png"),
                                           content_type: "image/png", disposition: :inline)
    assert_match(%r{\Ahttps://turf-monster-production\.sentinel-account\.r2\.cloudflarestorage\.com/abc123\?.*X-Amz-Signature=}, private_url)
  end

  # Rails' MirrorJob mirrors through the DEFAULT service whatever service a blob
  # names, so an og-image blob on amazon_public is mirrored by amazon's mirror.
  # That copies the right key only while each public name shares its private
  # twin's bucket on both stores.
  test "each public name shares its private twin's buckets, so the default mirror job covers it" do
    { amazon_public: :amazon, amazon_public_dev: :amazon_dev }.each do |public_name, twin|
      %w[mirror_to_r2 mirror_to_s3].each do |stage|
        pub, priv = build(public_name, stage), build(twin, stage)
        assert_equal priv.primary.bucket.name, pub.primary.bucket.name
        assert_equal endpoint_of(priv.primary), endpoint_of(pub.primary)
        assert_equal priv.mirrors.map { |m| [ endpoint_of(m), m.bucket.name ] },
                     pub.mirrors.map { |m| [ endpoint_of(m), m.bucket.name ] }
      end
    end
  end

  # Active Storage sends Content-MD5 and aws-sdk-s3 >= 1.178 adds a CRC32 by
  # default; R2 refuses a request carrying both (measured 2026-09-28).
  test "every R2 service computes checksums only when required" do
    NAMES.each do |name|
      [ build(name, "r2"), build(name, "mirror_to_r2").mirrors.first, build(name, "mirror_to_s3").primary ].each do |svc|
        assert_equal "when_required", svc.client.client.config.request_checksum_calculation, name
        assert_equal "when_required", svc.client.client.config.response_checksum_validation, name
      end
    end
  end

  test "a non-S3 stage without R2 credentials or a public domain fails at parse, not at first upload" do
    %w[R2_ENDPOINT R2_ACCESS_KEY_ID R2_PUBLIC_URL].each do |missing|
      with_env(R2_ENV.merge("ACTIVE_STORAGE_BACKEND" => "mirror_to_r2", missing => nil)) do
        error = assert_raises(ArgumentError) { parse }
        assert_match missing, error.message
      end
    end
  end

  test "development reaches a remote store with AWS keys on S3, and always off the S3 stage" do
    refute StorageBackend.remote_in_development?({})
    assert StorageBackend.remote_in_development?({ "AWS_ACCESS_KEY_ID" => "AKIA" })
    assert StorageBackend.remote_in_development?({ "ACTIVE_STORAGE_BACKEND" => "r2" })
  end

  test "studio_s3_settings is empty on S3 and carries the R2 connection and public domain on r2" do
    assert_equal({}, StorageBackend.studio_s3_settings({}))
    settings = StorageBackend.studio_s3_settings(R2_ENV.merge("STUDIO_S3_BACKEND" => "r2"))
    assert_equal R2_ENDPOINT, settings[:s3_endpoint]
    assert_equal "https://assets.example.test/", settings[:s3_public_url]
    assert_raises(ArgumentError) { StorageBackend.studio_s3_settings(R2_ENV.merge("STUDIO_S3_BACKEND" => "r2", "R2_PUBLIC_URL" => "")) }
  end

  private

  def parse = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))

  def build(name, stage, extra = {})
    with_env(R2_ENV.merge("ACTIVE_STORAGE_BACKEND" => stage).merge(extra)) do
      ActiveStorage::Service::Configurator.build(name, parse)
    end
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
