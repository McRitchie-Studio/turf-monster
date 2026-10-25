# frozen_string_literal: true

# DigestedAssetCache: a year of cache for a file whose name changes when it does.
#
# config.public_file_server.headers is one header for everything
# ActionDispatch::Static serves out of public/, and public/ holds two kinds of
# file. Fingerprinted /assets/* (the Sprockets digest is in the name, so an edit
# is a new URL) can be cached for a year and marked immutable. The files beside
# them (logo.png, og.png, the icons, robots.txt, site.webmanifest) keep their
# names when they are replaced, so a year there would pin a stale logo or
# manifest in browsers for a year. production.rb gives those a week; this raises
# the fingerprinted ones to a year (the UI infrastructure audit, P2). The hub runs
# the same middleware (mcritchie-studio lib/middleware/digested_asset_cache.rb).
#
# It sits just outside ActionDispatch::Static and rewrites only a 200 whose path
# is a digested asset, so a miss that falls through to the router (a 404) is
# never told to cache for a year.
class DigestedAssetCache
  ONE_YEAR = "public, max-age=#{365 * 24 * 60 * 60}, immutable".freeze

  # /assets/<logical name>-<64-hex Sprockets 4 digest>.<ext>[.gz|.br]
  DIGESTED = %r{\A/assets/.+-[0-9a-f]{64}\.[A-Za-z0-9.]+\z}

  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)
    if status.to_i == 200 && DIGESTED.match?(env["PATH_INFO"].to_s)
      # Rack 3 headers are lower-case, but a plain Hash may still carry the old
      # spelling (test.rb and development.rb write "Cache-Control"): drop every
      # case of the name so exactly one header goes out.
      headers.keys.each { |name| headers.delete(name) if name.to_s.casecmp?("cache-control") }
      headers["cache-control"] = ONE_YEAR
    end
    [status, headers, body]
  end
end
