# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/digested_asset_cache")

# PRODUCTION CACHES DIGESTED ASSETS FOR A YEAR AND NOTHING ELSE
# (task: turf-every-visitor-lang-main-cache; audit 2026-10-24, lane UI P2).
#
# production.rb set no public_file_server.headers, so ActionDispatch::Static
# served /assets/* with no Cache-Control and every page re-requested its
# 119-126 assets (measured on /contests). A digested filename changes when its
# content does, so a year is safe THERE. It is not safe for logo.png, og.png,
# the icons, robots.txt or site.webmanifest, which keep their names when they
# change: a blanket year would pin a stale logo or manifest in browsers for a
# year. So the year is DigestedAssetCache's, on digested paths only, and
# production.rb's public-file header stays a week.
#
# Three tiers, each a falsifier the others cannot be:
#   [unit]         the middleware's path rule, on a stub app.
#   [integration]  through this app's real stack: a digested file Static serves
#                  from public/assets carries the year, an undigested public
#                  file does not.
#   [unit]         production.rb's own header, read from the file (booting the
#                  production env needs its credentials and Redis): a week, so an
#                  undigested file there is never given a year either.
class DigestedAssetCacheTest < ActiveSupport::TestCase
  WEEK   = "public, max-age=604800"
  DIGEST = "a" * 64
  # Propshaft::Asset#digest: SHA1 cut to 8 hex. What Turf serves since
  # 2026-10-25 (task turf-moves-to-propshaft).
  PROPSHAFT = "3f9c0a1e"

  def call(path, status: 200, headers: { "cache-control" => WEEK })
    app = ->(_env) { [status, headers.dup, ["body"]] }
    DigestedAssetCache.new(app).call(Rack::MockRequest.env_for(path))
  end

  test "[unit] a digested asset gets a year, immutable" do
    %W[/assets/application-#{PROPSHAFT}.css /assets/solana_studio/wallet_transport-#{PROPSHAFT}.js
       /assets/application-#{PROPSHAFT}.css.gz /assets/controllers/card_filter_controller-#{PROPSHAFT}.js
       /assets/studio/montserrat-latin-#{PROPSHAFT}.woff2 /assets/bundle-abc123XYZ_-9.digested.js
       /assets/application-#{DIGEST}.css /assets/application-#{DIGEST}.css.gz].each do |path|
      _status, headers, _body = call(path)
      assert_equal "public, max-age=31536000, immutable", headers["cache-control"], path
    end
  end

  test "[unit] an old-spelling header is replaced, never doubled" do
    _status, headers, _body = call("/assets/application-#{DIGEST}.css", headers: { "Cache-Control" => WEEK })
    assert_equal ["cache-control"], headers.keys.select { |name| name.casecmp?("cache-control") }
    assert_equal DigestedAssetCache::ONE_YEAR, headers["cache-control"]
  end

  test "[unit] an unfingerprinted file keeps the header it was given" do
    ["/logo.png", "/og.png", "/icon-512.png", "/robots.txt", "/site.webmanifest", "/assets/application.css",
     "/assets/studio/montserrat-latin.woff2", "/assets/solana_studio/wallet_transport.js",
     "/assets/application-#{'a' * 7}.css", "/assets/application-#{'a' * 9}.css",
     "/assets/application-#{'a' * 63}.css", "/assets/application-ABCDEF12.css",
     "/assets/-#{PROPSHAFT}", "/brand/logo-#{PROPSHAFT}.png", "/brand/logo-#{DIGEST}.png"].each do |path|
      _status, headers, _body = call(path)
      assert_equal WEEK, headers["cache-control"], path
    end
  end

  test "[unit] a miss is never cached for a year" do
    _status, headers, _body = call("/assets/application-#{DIGEST}.css", status: 404, headers: {})
    assert_nil headers["cache-control"]
  end

  test "[unit] production.rb gives undigested public files a week, not a year" do
    assignment = /^\s*config\.public_file_server\.headers\s*=\s*(\{.*\})\s*$/
    lines = Rails.root.join("config/environments/production.rb").read.lines.grep(assignment)
    assert_equal 1, lines.size, "production.rb must assign public_file_server.headers exactly once, uncommented"
    headers = eval(lines.first[assignment, 1]) # rubocop:disable Security/Eval -- our own config file, not input

    assert_equal "public, max-age=#{1.week.to_i}", headers["cache-control"]
  end

  test "[unit] the middleware sits outside ActionDispatch::Static" do
    stack = Rails.application.middleware.map(&:klass)
    assert_includes stack, DigestedAssetCache
    assert_operator stack.index(DigestedAssetCache), :<, stack.index(ActionDispatch::Static)
  end

  # Through the real stack: ActionDispatch::Static serves the file from
  # public/assets, and the header that reaches the client is the year. The probe
  # is named the way Propshaft names a file: an 8-hex digest.
  class ThroughStaticTest < ActionDispatch::IntegrationTest
    setup do
      @file = Rails.root.join("public/assets/digested-asset-cache-probe-#{SecureRandom.hex(4)}.txt")
      @made_dir = !@file.dirname.exist?
      FileUtils.mkdir_p(@file.dirname)
      File.write(@file, "probe")
    end

    # Leave public/ as it was: a stray public/assets breaks a release check.
    teardown do
      FileUtils.rm_f(@file)
      Dir.rmdir(@file.dirname) if @made_dir && Dir.empty?(@file.dirname)
    end

    test "[integration] a digested file served from public/assets carries a year" do
      get "/assets/#{@file.basename}"

      assert_response :success
      assert_equal "probe", response.body
      assert_equal DigestedAssetCache::ONE_YEAR, response.headers["cache-control"]
    end

    test "[integration] an undigested public file does not" do
      get "/robots.txt"

      assert_response :success
      assert_not_nil response.headers["cache-control"], "Static must have served it, with its own header"
      assert_no_match(/max-age=31536000/, response.headers["cache-control"])
    end
  end
end
