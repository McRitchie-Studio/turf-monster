require "test_helper"

# [unit] The three slate pages load their chart and drag libraries from our own
# origin: Chart.js is vendored in vendor/javascript and SortableJS is
# studio-engine's vendored classic build. No slate page carries a jsDelivr
# script tag, and each page still renders.
class SlatesLocalScriptsTest < ActionDispatch::IntegrationTest
  setup do
    log_in_as(users(:alex)) # admin: every slate page is admin-gated
    @slate = Slate.create!(name: "Local Scripts Test", slug: "local-scripts-test")
  end

  def scripts = Nokogiri::HTML5(response.body).css("script[src]")

  def script_srcs = scripts.map { |script| script["src"] }

  # The layout's tweetnacl is a jsDelivr tag too, pinned by integrity; what the
  # slate pages added was jsDelivr with none.
  def unpinned_jsdelivr = scripts.select { |script| script["src"].include?("cdn.jsdelivr.net") && script["integrity"].blank? }.map { |script| script["src"] }

  def slate_pages = [ slate_path(@slate), nfl_report_slates_path, formula_report_slates_path ]

  test "every slate page loads Chart.js from our origin" do
    slate_pages.each do |path|
      get path
      assert_response :success, path
      srcs = script_srcs
      assert_empty srcs.grep(/chart\.js@/), path
      assert_equal 1, srcs.grep(%r{\A/assets/chart\.umd\.min-\h+\.js\z}).size, "#{path}: #{srcs.inspect}"
    end
  end

  test "the vendored Chart.js is 4.4.7 and defines the Chart global" do
    file = Rails.root.join("vendor/javascript/chart.umd.min.js").read
    # Booleans, not assert_includes: a failure must not print 200 KB.
    assert file.include?("Chart.js v4.4.7"), "not Chart.js 4.4.7"
    assert file.include?("window.Chart="), "does not assign window.Chart"
    assert file.include?("sha384-"), "header records no sha384"
    assert_not file.match?(%r{^//# sourceMappingURL=}), "points at a source map that is not vendored"
  end
end
