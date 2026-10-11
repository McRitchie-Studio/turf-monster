require "test_helper"
require "rake"
require "aws-sdk-s3"

# NFL headshots are SEED ASSETS: they live in turf-monster-production, and a
# non-production process REFERENCES production's copy instead of uploading a
# duplicate into turf-monster-dev (studio-engine 0.103.0,
# Studio::ImageCache.reference_or_cache!; docs/object-storage in the hub, "Seed
# assets"). Both writers go through Nflverse::SeedPlayers.cache_headshot!:
# the seeder (nfl:players_seed) and nfl:upload_headshots.
#
# NOTHING HERE TOUCHES THE NETWORK. Studio::S3's client is an aws-sdk stub that
# records every request, the ESPN fetch and its SSRF lookup are stubbed, and
# config/initializers/studio.rb leaves s3_production_public_url nil in test, so
# each test that needs the knob sets it and puts it back.
class Nflverse::HeadshotReferenceTest < ActiveSupport::TestCase
  PRODUCTION_HOST = "https://assets.turfmonster.media".freeze
  ESPN_URL = "https://a.espncdn.com/i/headshots/nfl/players/full/4567890.png".freeze
  PNG = File.binread(Rails.root.join("test/fixtures/files/headshot.png")).freeze

  setup do
    @previous_production_url = Studio.s3_production_public_url
    Studio.s3_production_public_url = PRODUCTION_HOST
    person = Person.create!(first_name: "Kenneth", last_name: "Headshotte")
    @athlete = Athlete.create!(person_slug: person.slug, sport: "football",
                               espn_id: 4_567_890, espn_headshot_url: ESPN_URL)
    @prefix = "headshots/nfl/free-agents/#{@athlete.person_slug}"
  end

  teardown do
    Studio.s3_production_public_url = @previous_production_url
  end

  # An aws-sdk client that answers HEAD per key from `production_keys` and
  # accepts every PUT. Requests land in client.api_requests.
  def s3_client(production_keys: [])
    client = Aws::S3::Client.new(stub_responses: true, region: "auto")
    client.stub_responses(:head_object, lambda { |ctx|
      if production_keys.include?(ctx.params[:key])
        { content_length: 4321, content_type: "image/png" }
      else
        "NotFound"
      end
    })
    client
  end

  def with_storage(client, environment: nil, &block)
    fetches = []
    fetch = ->(url, **) { fetches << url; PNG }
    Studio::ImageCache.stub(:validate_source_url!, ->(*, **) { }) do
      Studio::ImageCache.stub(:fetch_remote, fetch) do
        Studio::S3.stub(:client, client) do
          if environment
            Studio::S3.stub(:environment, environment) { block.call(fetches) }
          else
            block.call(fetches)
          end
        end
      end
    end
  end

  def requests(client, operation)
    client.api_requests.select { |r| r[:operation_name] == operation }.map { |r| r[:params] }
  end

  def all_keys
    %w[original 100 400].map { |variant| "#{@prefix}/#{variant}.png" }
  end

  test "[unit] the seeder records production references when production holds every key" do
    client = s3_client(production_keys: all_keys)
    rows = with_storage(client) { Nflverse::SeedPlayers.cache_headshot!(@athlete) }

    assert_equal %w[100 400 original], rows.keys.sort
    rows.each_value do |row|
      assert_equal ImageCache::PRODUCTION, row.reload.stored_in
      assert_equal 4321, row.bytes
    end
    assert_equal "turf-monster-production", requests(client, :head_object).map { |p| p[:bucket] }.uniq.sole
    assert_empty requests(client, :put_object), "a referenced headshot must upload nothing"
  end

  test "[unit] reference rows resolve on assets.turfmonster.media, not the dev host" do
    client = s3_client(production_keys: all_keys)
    with_storage(client) { Nflverse::SeedPlayers.cache_headshot!(@athlete) }

    url = @athlete.reload.headshot_url(width: 400)
    assert_equal "#{PRODUCTION_HOST}/#{@prefix}/400.png", url
    refute_includes url, "assets-dev."
  end

  # kenneth-walker-iii was dev-only on 2026-10-10: production lacked the key, so
  # the fallback is what gives a new player any image at all.
  test "[unit] the seeder uploads to the dev bucket when production lacks the key" do
    client = s3_client(production_keys: [])
    fetches = nil
    rows = with_storage(client) do |f|
      fetches = f
      Nflverse::SeedPlayers.cache_headshot!(@athlete)
    end

    assert_equal [ESPN_URL], fetches, "the source is fetched once, only because an upload is owed"
    puts_ = requests(client, :put_object)
    assert_equal all_keys.sort, puts_.map { |p| p[:key] }.sort
    assert_equal "turf-monster-dev", puts_.map { |p| p[:bucket] }.uniq.sole
    rows.each_value { |row| assert_nil row.reload.stored_in, "an upload is the process's own object" }
    assert_equal "#{StorageBackend::DEV_PUBLIC_URL}/#{@prefix}/400.png", @athlete.reload.headshot_url(width: 400)
  end

  test "[unit] a partial production copy references what exists and uploads the rest" do
    client = s3_client(production_keys: all_keys.first(2))
    rows = with_storage(client) { Nflverse::SeedPlayers.cache_headshot!(@athlete) }

    assert_equal ImageCache::PRODUCTION, rows["original"].stored_in
    assert_equal ImageCache::PRODUCTION, rows["100"].stored_in
    assert_nil rows["400"].stored_in
    assert_equal ["#{@prefix}/400.png"], requests(client, :put_object).map { |p| p[:key] }
  end

  # Production must behave exactly as before 0.103.0: no HEAD, every variant
  # uploaded to the production bucket, no reference rows. Studio::S3 resolves
  # the environment the way a production dyno does.
  test "[unit] production uploads to its own bucket and never sends a HEAD" do
    client = s3_client(production_keys: all_keys)
    rows = with_storage(client, environment: "production") { Nflverse::SeedPlayers.cache_headshot!(@athlete) }

    assert_empty requests(client, :head_object), "production must not look itself up"
    puts_ = requests(client, :put_object)
    assert_equal all_keys.sort, puts_.map { |p| p[:key] }.sort
    assert_equal "turf-monster-production", puts_.map { |p| p[:bucket] }.uniq.sole
    rows.each_value { |row| assert_nil row.reload.stored_in }
    assert_equal "#{StorageBackend::DEV_PUBLIC_URL}/#{@prefix}/400.png", rows["400"].url,
                 "production's rows resolve on Studio.s3_public_url, as before (the test boot's base)"
  end

  # The suite's own boot leaves the knob nil, which makes reference_or_cache!
  # plain cache!: no test can send a live HEAD to production by accident.
  test "[unit] with the production URL unset the seeder never sends a HEAD" do
    Studio.s3_production_public_url = nil
    client = s3_client(production_keys: all_keys)
    with_storage(client) { Nflverse::SeedPlayers.cache_headshot!(@athlete) }

    assert_empty requests(client, :head_object)
    assert_equal 3, requests(client, :put_object).size
  end

  test "[unit] the initializer leaves the production URL nil in test and names the production host" do
    assert_nil @previous_production_url, "test must boot with s3_production_public_url nil"
    initializer = Rails.root.join("config/initializers/studio.rb").read
    assert_match(/config\.s3_production_public_url = StorageBackend::PRODUCTION_PUBLIC_URL unless Rails\.env\.test\?/,
                 initializer)
    assert_equal PRODUCTION_HOST, StorageBackend::PRODUCTION_PUBLIC_URL
  end

  test "[integration] nfl:upload_headshots references production through the same call" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("nfl:upload_headshots")
    Athlete.where.not(id: @athlete.id).where.not(espn_id: nil).update_all(espn_id: nil)
    client = s3_client(production_keys: all_keys)

    out = nil
    with_storage(client) do
      task = Rake::Task["nfl:upload_headshots"]
      task.reenable
      out, = capture_io { task.invoke }
    end

    assert_match(/cached:\s+1/, out)
    rows = @athlete.image_caches.reload.where(purpose: "headshot")
    assert_equal %w[100 400 original], rows.map(&:variant).sort
    assert(rows.all?(&:production_reference?), "the rake task must record references, not uploads")
    assert_empty requests(client, :put_object)
  end
end
