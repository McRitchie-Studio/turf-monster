require "test_helper"
require "digest"
require "base64"

# [unit] The layout's two wallet libraries load from this app, under their pins.
#
# web3.js and tweetnacl were blocking head tags on unpkg and jsDelivr. A CDN
# connection that never answered held every page until net::ERR_TIMED_OUT at 30
# seconds, which is the Playwright test timeout (turf-e2e-retry-only-causes). They
# are vendored now, and three things must stay true for a browser to run them:
# the layout names the vendored file, its integrity is the file's sha384, and
# Propshaft serves the file's bytes unchanged (it rewrites or drops a
# sourceMappingURL comment, which is why web3.js lost its last line).
class VendoredWalletScriptsTest < ActionDispatch::IntegrationTest
  FILES = {
    "solana-web3-1.98.4.iife.min.js" => "sha384-AfVKPfUHqd84hOcem33IqhD+4XSy5Bd146b5pOLLfzWkRdYj4BFp6jx4z9oxSLCw",
    "tweetnacl-1.0.3-nacl-fast.min.js" => "sha384-05+sicyRJQ56XpL4U9HJ8YbtSzFDvAg7apPKOGV6A0JsAJKFM68jp5oLnUjG5mEp"
  }.freeze

  def sri(bytes) = "sha384-#{Base64.strict_encode64(Digest::SHA384.digest(bytes))}"

  test "each pin is the sha384 of the vendored file and of what Propshaft serves" do
    FILES.each do |name, integrity|
      asset = Rails.application.assets.load_path.find(name)
      assert asset, "#{name} is not on the asset load path"
      assert_equal integrity, sri(File.binread(Rails.root.join("vendor/javascript", name))), name
      assert_equal integrity, sri(asset.compiled_content), "#{name}: Propshaft changes the bytes it serves"
    end
  end

  test "the rendered layout loads both from this app, pinned, and nothing from unpkg or jsDelivr" do
    get help_path
    assert_response :success
    FILES.each do |name, integrity|
      tag = response.body[%r{<script[^>]*src="/assets/#{Regexp.escape(name.delete_suffix('.js'))}-[0-9a-f]+\.js"[^>]*>}]
      assert tag, "the layout no longer loads #{name} from this app"
      assert_includes tag, %(integrity="#{integrity}")
      assert_includes tag, %(crossorigin="anonymous")
    end
    assert_no_match %r{<script[^>]*src="https://(unpkg\.com|cdn\.jsdelivr\.net)/}, response.body
  end
end
