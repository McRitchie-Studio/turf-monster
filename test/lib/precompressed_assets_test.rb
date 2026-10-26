# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/precompressed_assets")

# [unit] PrecompressedAssets (lib/precompressed_assets.rb): Propshaft writes no
# .gz beside an asset, so assets:precompile writes one for each digested css
# and js, and assets:clean prunes the ones whose source is gone.
class PrecompressedAssetsTest < ActiveSupport::TestCase
  setup { @root = Pathname(Dir.mktmpdir("precompressed-assets")) }
  teardown { FileUtils.rm_rf(@root) }

  def put(name, body = "body { color: red; }\n" * 100)
    path = @root.join(name)
    FileUtils.mkdir_p(path.dirname)
    File.write(path, body)
    path
  end

  test "writes a .gz that inflates to the source for each digested css, js and svg" do
    css = put("application-3f9c0a1e.css")
    svg = put("state-flags/co-4d5e6f70.svg", "<svg><path d=\"M0 0\"/></svg>\n" * 100)
    js = put("controllers/tabs_controller-0a1b2c3d.js", "export default 1;\n" * 100)
    bundled = put("bundle-abc123XYZ_-9.digested.js")

    written = PrecompressedAssets.write(@root)

    assert_equal [css, js, bundled, svg].map { |p| "#{p}.gz" }.sort, written.sort
    [css, js, bundled, svg].each do |source|
      assert_equal source.binread, ActiveSupport::Gzip.decompress(File.binread("#{source}.gz")), source.basename.to_s
    end
  end

  test "skips an undigested file, an image, a font and an existing .gz" do
    put("application.css")
    put("logo-3f9c0a1e.png")
    put("state-flags/co.svg") # undigested
    put("studio/montserrat-latin-3f9c0a1e.woff2")
    put("application-3f9c0a1.css") # 7 hex: not a Propshaft digest
    put(".manifest.json", "{}")

    assert_empty PrecompressedAssets.write(@root)
    assert_empty Dir.glob(@root.join("**/*.gz").to_s)
  end

  test "is idempotent: a current .gz is not rewritten, a stale one is" do
    css = put("application-3f9c0a1e.css")
    assert_equal 1, PrecompressedAssets.write(@root).size
    assert_empty PrecompressedAssets.write(@root), "a second run must not rewrite a current .gz"

    File.utime(Time.now + 60, Time.now + 60, css)
    assert_equal ["#{css}.gz"], PrecompressedAssets.write(@root)
  end

  test "prune deletes only a .gz whose source is gone" do
    kept = put("application-3f9c0a1e.css")
    gone = put("application-0000aaaa.css")
    PrecompressedAssets.write(@root)
    gone.delete

    assert_equal ["#{gone}.gz"], PrecompressedAssets.prune(@root)
    assert File.exist?("#{kept}.gz")
    refute File.exist?("#{gone}.gz")
  end
end
