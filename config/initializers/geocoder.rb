# Cross-session, cross-dyno cache for IP lookups, keyed by the full lookup URL
# (which embeds the IP). The session already remembers a resolved state for
# 24h, but a visitor with NO session — every uptime-monitor hit, every first
# page load — pays a fresh ipinfo call. On the anonymous tier those calls
# share one rate limit with every other tenant on the dyno's shared egress IP,
# so lookups 429 and geo_state goes blank: the navbar badge reads "??" and the
# fail-closed gates (CDP ramp, state blocklist) treat the visitor as blocked.
# Caching by IP collapses repeat visitors and the per-minute monitor to one
# lookup per TTL. Geocoder writes the cache only for VALID responses
# (Geocoder::Lookup::Base#fetch_raw_data), so a 429/timeout is never cached
# and simply retries on the next request.
#
# Guarded because test/initializers/geocoder_initializer_test.rb re-`load`s
# this file, which would otherwise redefine the class and warn.
unless defined?(GeocoderRailsCache)
  # Adapts Rails.cache to the []/[]= duck geocoder's Generic cache store
  # prefers, adding the TTL Rails.cache.write supports but geocoder never
  # passes. Unknown store classes fall back to Geocoder::CacheStore::Generic,
  # which is exactly the branch this duck satisfies.
  class GeocoderRailsCache
    EXPIRES_IN = 24.hours

    def [](url)
      Rails.cache.read(url)
    end

    def []=(url, value)
      Rails.cache.write(url, value, expires_in: EXPIRES_IN)
    end
  end
end

Geocoder.configure(
  ip_lookup: :ipinfo_io,
  # Authenticated ipinfo lifts the anonymous-tier rate limit. Under load the
  # free/anonymous endpoint starts returning no region (or 429s), which makes
  # geo_state blank — failing the CDP ramp closed ("not available in your
  # state") for every US user, the only funding rail when Stripe is disabled.
  # A blank/nil token is a safe no-op (the anonymous tier, today's behavior),
  # so this is dormant until IPINFO_API_TOKEN is set in the environment.
  ipinfo_io: { api_key: ENV["IPINFO_API_TOKEN"].presence },
  # ipinfo.io 301-redirects http -> https with a non-JSON body, and Geocoder
  # does not follow the redirect — a plain-HTTP lookup silently returns no
  # result ("response was not valid JSON"). Without a detected state, the CDP
  # ramp catalog fails closed ("not available in your region") for every US
  # user and the GeoSetting state blocklist stops enforcing. Force HTTPS.
  use_https: true,
  timeout: 3,
  units: :mi,
  cache: GeocoderRailsCache.new,
  cache_options: { prefix: "geocoder:" }
)
