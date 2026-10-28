# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require Rails.root.join("lib/precompressed_assets")

# [integration] A digested stylesheet or script is served PRE-ENCODED and never
# compressed again (task turf-moves-to-propshaft, Carl's review correction 2).
#
# Sprockets wrote a .gz beside each asset; Propshaft writes none, so without
# assets:precompress (lib/precompressed_assets.rb) Static serves the identity
# file. Static answers before Rack::Deflater is reached, so that file goes out
# uncompressed; Deflater cannot rescue it (the control test below shows it).
#
# Two stacks, because the test stack is not production's: development and test
# run Propshaft::Server after Static (config.assets.server), production does not.
#   * The app's own stack: Rails.application.middleware, every middleware in the
#     app's order, with only Static's root swapped (see below).
#   * A production-shaped stack: Static, then Deflater with the app's own policy
#     (ResponseCompression.compress?), then a 404 app, in production's order,
#     with no Propshaft::Server.
# Each asserts the response carries Content-Encoding: gzip and its bytes ARE the
# .gz on disk, which Deflater could not produce (it stamps its own header and
# mtime), so a second compression or an on-the-fly one is caught too.
#
# A PRIVATE PUBLIC ROOT PER TEST (task turf-asset-test-stops-racing). The probe
# used to live under the app's real public/assets, which this test created when
# absent and removed when empty. CI runs the suite in parallel workers, and two
# workers that both found public/assets absent each owned its removal: one
# worker's teardown rmdir'd it between another's mkdir_p of the parent and of
# the probe directory (Errno::ENOENT, turf PR #1024's first CI run). Each test
# now writes into its own Dir.mktmpdir and points Static there, so nothing under
# the shared public/ is created or deleted and no worker can see another's files.
class PrecompressedAssetServingTest < ActionDispatch::IntegrationTest
  GZIP = { "Accept-Encoding" => "gzip, deflate, br" }.freeze
  BODY = (".turf-probe { color: rgb(var(--color-primary) / 1); }\n" * 200).freeze

  setup do
    @public = Pathname(Dir.mktmpdir("precompressed-probe-public"))
    @dir = @public.join("assets/precompressed-probe-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@dir)
    @css = @dir.join("probe-#{SecureRandom.hex(4)}.css")
    File.write(@css, BODY)
    @url = "/#{@css.relative_path_from(@public)}"
  end

  teardown { FileUtils.rm_r(@public) }

  def gz_bytes = File.binread("#{@css}.gz")

  def assert_served_precompressed(status, headers, body)
    assert_equal 200, status.to_i
    assert_equal "gzip", headers["content-encoding"], "a digested stylesheet must arrive gzip-encoded"
    assert_equal gz_bytes, body, "the bytes must be the .gz on disk, not a fresh (or second) compression"
    assert_equal BODY, ActiveSupport::Gzip.decompress(body), "one inflate must give back the stylesheet"
    assert_includes headers["vary"].to_s.downcase, "accept-encoding"
  end

  # The app's own middleware stack, built as Rails builds it (MiddlewareStack#build
  # over the routes), with ActionDispatch::Static's root swapped to this test's
  # private public dir and its options kept. Everything else (DigestedAssetCache
  # outside Static, Propshaft::Server and Rack::Deflater inside it) is the app's.
  def app_stack
    static = Rails.application.middleware.middlewares.find { |m| m.klass == ActionDispatch::Static }
    assert static, "the app's stack must carry ActionDispatch::Static"
    _root, options = static.args
    stack = Rails.application.middleware.dup
    stack.swap(ActionDispatch::Static, ActionDispatch::Static, @public.to_s, **options)
    stack.build(Rails.application.routes)
  end

  def call_stack(stack, headers = GZIP)
    env = Rack::MockRequest.env_for(@url, headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" })
    status, response_headers, body = stack.call(env)
    chunks = +"".b
    body.each { |chunk| chunks << chunk.b }
    body.close if body.respond_to?(:close)
    [status, response_headers, chunks]
  end

  test "through the app's stack, Static serves the .gz and Deflater leaves it alone" do
    PrecompressedAssets.write(@dir)

    status, headers, body = call_stack(app_stack)

    assert_served_precompressed(status, headers, body)
    assert_equal DigestedAssetCache::ONE_YEAR, headers["cache-control"]
  end

  def production_stack
    not_found = ->(_env) { [404, { "content-type" => "text/plain" }, ["not found"]] }
    deflater = Rack::Deflater.new(not_found, if: ResponseCompression.method(:compress?), sync: false)
    static = ActionDispatch::Static.new(deflater, @public.to_s,
                                        headers: { "cache-control" => "public, max-age=604800" })
    DigestedAssetCache.new(static)
  end

  def call_production(headers = GZIP) = call_stack(production_stack, headers)

  test "through a production-shaped stack, the digested asset is served pre-encoded" do
    PrecompressedAssets.write(@dir)

    assert_served_precompressed(*call_production)
  end

  test "a client that sends no Accept-Encoding gets the identity file" do
    PrecompressedAssets.write(@dir)

    status, headers, body = call_production({})
    assert_equal 200, status.to_i
    assert_nil headers["content-encoding"]
    assert_equal BODY, body
  end

  # The control: what correction 2 is about. Without the .gz, Static serves the
  # identity file and never calls inward, so Deflater never sees it and the
  # stylesheet goes out uncompressed. This is the regression the tests above
  # would catch if the precompress hook were lost.
  test "without the precompress step, Static serves the stylesheet uncompressed" do
    status, headers, body = call_production
    assert_equal 200, status.to_i
    assert_nil headers["content-encoding"], "Static found no .gz, so nothing pre-encoded went out"
    assert_equal BODY, body
  end
end
