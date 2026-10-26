require "test_helper"

# [integration] Every asset a page links resolves through Propshaft (task
# turf-moves-to-propshaft; adapted from rolio's test/integration/asset_urls_test.rb).
#
# A fingerprinted URL (name-<8 hex>.ext) that answers 200 with bytes. This covers
# the stylesheets (the engine head links "tailwind" and "application" by name),
# the classic scripts (studio/alpine, the five solana_studio wallet scripts,
# Chart.js), the importmap's JSON pins and its modulepreload links, and any
# <img src> under /assets. A missing stylesheet or image raises at render time
# under Propshaft, but importmap-rails RESCUES a pin whose file is missing and
# silently drops it from the map, so the pins get their own check below.
class AssetUrlsTest < ActionDispatch::IntegrationTest
  DIGESTED = %r{\A/assets/.+-[0-9a-f]{8}\.[a-z0-9]+\z}

  def asset_urls_on(path)
    get path
    follow_redirect! while response.redirect?
    assert_response :success, "#{path} did not render"

    html = response.body
    urls = html.scan(%r{(?:href|src)="(?:https?://[^/"]+)?(/assets/[^"]+)"}).flatten
    importmap = html[%r{<script type="importmap"[^>]*>(.*?)</script>}m, 1]
    refute_nil importmap, "#{path} lost its importmap"
    urls += JSON.parse(importmap).fetch("imports").values.map { |url| url.sub(%r{\Ahttps?://[^/]+}, "") }
    urls.uniq
  end

  def check(pages)
    checked = pages.flat_map { |page| asset_urls_on(page).map { |url| [page, url] } }.uniq(&:last)

    checked.each do |page, url|
      assert_match DIGESTED, url, "#{page} links an undigested asset"
      get url
      assert_response :success, "#{url} (linked from #{page}) did not resolve"
      refute_empty response.body, "#{url} served no bytes"
    end
    checked.map(&:last)
  end

  test "every asset on the signed-out pages is fingerprinted and answers 200" do
    urls = check(["/", contests_path, contest_path(contests(:one)), live_path, help_path])

    %w[tailwind application studio/alpine solana_studio/wallet_transport solana_studio/wallet_ops
       solana_studio/wallet_identity @hotwired/turbo turf_stimulus wallet_provider].each do |name|
      stem = name.sub("@hotwired/turbo", "turbo")
      assert urls.any? { |url| url.include?("/#{stem}") }, "no page linked #{name}"
    end
  end

  test "every asset on the signed-in pages, navbar and gear sidebar included, is fingerprinted and answers 200" do
    log_in_as(users(:jordan))

    urls = check([contests_path, contest_path(contests(:one)), account_path])
    assert urls.any? { |url| url.end_with?(".css") }, "no stylesheet was linked"
  end

  # The vendored scripts: Chart.js (vendor/javascript) and SortableJS through
  # the engine (studio/sortable), both classic tags on the admin slate page.
  test "the slate page's vendored Chart.js and the engine's SortableJS are fingerprinted and answer 200" do
    log_in_as(users(:alex))
    slate = Slate.create!(name: "Asset Urls Test", slug: "asset-urls-test")

    urls = check([slate_path(slate)])
    assert urls.any? { |url| url.include?("/chart.umd.min-") }, "Chart.js is no longer linked"
    assert urls.any? { |url| url.include?("/studio/sortable-") }, "the engine's SortableJS is no longer linked"
  end

  test "every importmap pin, the engine's included, resolves to a fingerprinted asset" do
    helpers = ActionController::Base.helpers
    pins = Rails.application.importmap.packages
    assert_operator pins.size, :>, 50, "the map lost most of its pins"
    %w[application studio/host_fetchers @hotwired/stimulus sortablejs turf_stimulus wallet_provider].each do |name|
      assert pins.key?(name), "pin #{name} is gone"
    end
    assert pins.keys.any? { |name| name.start_with?("studio/") && name != "studio/host_fetchers" },
           "the engine's pins were not drawn"

    pins.each do |name, package|
      url = helpers.asset_path(package.path)
      assert_match DIGESTED, url, "pin #{name} resolves undigested"
    rescue Propshaft::MissingAssetError => e
      flunk "pin #{name} points at a file Propshaft cannot find: #{e.message}"
    end
  end

  # studio/host_fetchers is pinned twice: the engine's empty module, then
  # Turf's map (drawn last) to app/javascript/host_fetchers.js. The host's must win.
  test "studio/host_fetchers resolves to Turf's own module" do
    assert_equal "host_fetchers.js", Rails.application.importmap.packages.fetch("studio/host_fetchers").path
  end
end
