require "test_helper"

# Regression guard for config/initializers/geocoder.rb.
#
# ipinfo.io 301-redirects http://ipinfo.io/<ip>/geo -> https with an empty,
# non-JSON body. Geocoder does NOT follow that redirect, so a plain-HTTP lookup
# silently yields "response was not valid JSON" -> no result. When IP
# geolocation fails, geo_state goes blank and geo_country defaults to "US",
# which makes Cdp::Catalog#available? fail closed ("not available in your
# region") for every US user AND silently disables the GeoSetting state
# blocklist (blocked?(nil) == false). The fix is use_https: true; this test
# fails if anyone drops it.
class GeocoderInitializerTest < ActiveSupport::TestCase
  test "geocoder is configured to call ipinfo over HTTPS" do
    assert Geocoder.config.use_https,
           "Geocoder.config.use_https must be true — ipinfo 301-redirects http->https and Geocoder won't follow it"
  end

  test "the ipinfo_io lookup builds an https query URL" do
    assert_equal :ipinfo_io, Geocoder.config.ip_lookup,
                 "expected the IP lookup to stay :ipinfo_io"

    url = Geocoder::Lookup.get(:ipinfo_io).send(:query_url, Geocoder::Query.new("8.8.8.8"))
    assert url.start_with?("https://"),
           "ipinfo lookup must use https (plain http 301-redirects to a non-JSON body); got #{url}"
  end

  # IPINFO_API_TOKEN lifts the anonymous rate limit that otherwise makes lookups
  # return no region under load — failing the CDP ramp closed for every US user.
  # Reloading the initializer with the env var set proves it is wired through to
  # the lookup's token param.
  test "IPINFO_API_TOKEN from the environment is forwarded to the ipinfo lookup" do
    previous = ENV["IPINFO_API_TOKEN"]
    ENV["IPINFO_API_TOKEN"] = "test-ipinfo-token-123"
    load Rails.root.join("config/initializers/geocoder.rb").to_s

    url = Geocoder::Lookup.get(:ipinfo_io).send(:query_url, Geocoder::Query.new("8.8.8.8"))
    assert_includes url, "token=test-ipinfo-token-123",
                    "a configured IPINFO_API_TOKEN must be sent to ipinfo as the token param"
  ensure
    if previous.nil?
      ENV.delete("IPINFO_API_TOKEN")
    else
      ENV["IPINFO_API_TOKEN"] = previous
    end
    # Restore the real (token-less in test) configuration for later tests.
    load Rails.root.join("config/initializers/geocoder.rb").to_s
  end

  test "no IPINFO_API_TOKEN leaves the anonymous lookup intact (safe no-op)" do
    previous = ENV["IPINFO_API_TOKEN"]
    ENV.delete("IPINFO_API_TOKEN")
    load Rails.root.join("config/initializers/geocoder.rb").to_s

    url = Geocoder::Lookup.get(:ipinfo_io).send(:query_url, Geocoder::Query.new("8.8.8.8"))
    assert url.start_with?("https://"),
           "the token-less lookup must still build a valid https URL (today's anonymous behavior)"
    refute_includes url, "test-ipinfo-token-123"
  ensure
    ENV["IPINFO_API_TOKEN"] = previous unless previous.nil?
    load Rails.root.join("config/initializers/geocoder.rb").to_s
  end

  # ── lookup caching (rate-limit armor) ──────────────────────────────────────
  # The anonymous ipinfo tier rate-limits by requesting IP, and Heroku dynos
  # share egress IPs — so uncached lookups 429 under load, geo_state goes
  # blank, and the fail-closed gates block real users. The cache collapses
  # repeat-IP lookups (returning visitors, per-minute uptime monitors) to one
  # ipinfo call per TTL.

  test "geocoder is configured to cache lookups in Rails.cache" do
    assert_instance_of GeocoderRailsCache, Geocoder.config.cache,
                       "lookups must be cached — uncached ipinfo calls 429 on the shared anonymous tier"
    assert_equal "geocoder:", Geocoder.config.cache_options[:prefix]
  end

  test "the cache wrapper writes through Rails.cache with a bounded TTL" do
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stub :cache, store do
      cache = GeocoderRailsCache.new
      cache["geocoder:https://example.test/1.2.3.4/geo"] = "{\"region\":\"Colorado\"}"

      assert_equal "{\"region\":\"Colorado\"}", cache["geocoder:https://example.test/1.2.3.4/geo"],
                   "a cached body must read back"

      travel GeocoderRailsCache::EXPIRES_IN + 1.minute do
        assert_nil cache["geocoder:https://example.test/1.2.3.4/geo"],
                   "an IP's geolocation drifts — the cache must expire, not pin it forever"
      end
    end
  end

  test "a cache miss reads as nil so geocoder falls through to the live lookup" do
    Rails.stub :cache, ActiveSupport::Cache::MemoryStore.new do
      assert_nil GeocoderRailsCache.new["geocoder:https://example.test/miss/geo"]
    end
  end
end
