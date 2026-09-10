require "test_helper"

# The IP lookup this app boots with. The configuration moved into the engine
# (Studio::Geo::Lookup, studio-engine >= 0.57) — this guard did not, because the
# failure it pins is this app's scar and it is invisible when it happens.
#
# ipinfo.io 301-redirects http://ipinfo.io/<ip>/geo -> https with an empty,
# non-JSON body, and Geocoder does not follow the redirect. A plain-HTTP lookup
# therefore yields "response was not valid JSON" -> no result. Geo then goes
# blank for everyone: Cdp::Catalog#available? fails closed ("not available in
# your region") for every US user, and the state blocklist stops enforcing. The
# fix is use_https; this test fails if any app or engine change drops it.
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

  # Lookups are cached across processes, keyed by the lookup URL (which embeds
  # the IP). Without it the anonymous tier's rate limit — shared with every other
  # tenant on the platform's egress IP — blanks every visitor under load.
  test "IP lookups are cached" do
    refute_nil Geocoder.config.cache, "geo lookups must be cached, not re-fetched per request"
  end

  # IPINFO_API_TOKEN lifts that rate limit. Re-running the engine's configuration
  # with the env var set proves it is wired through to the lookup's token param.
  test "IPINFO_API_TOKEN from the environment is forwarded to the ipinfo lookup" do
    previous = ENV["IPINFO_API_TOKEN"]
    ENV["IPINFO_API_TOKEN"] = "test-ipinfo-token-123"
    Studio::Geo::Lookup.configure!

    url = Geocoder::Lookup.get(:ipinfo_io).send(:query_url, Geocoder::Query.new("8.8.8.8"))
    assert_includes url, "token=test-ipinfo-token-123",
                    "a configured IPINFO_API_TOKEN must be sent to ipinfo as the token param"
  ensure
    if previous.nil?
      ENV.delete("IPINFO_API_TOKEN")
    else
      ENV["IPINFO_API_TOKEN"] = previous
    end
    # Restore the app's booted configuration for every later test in the process.
    Studio::Geo::Lookup.configure!
  end
end
