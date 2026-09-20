require "test_helper"

# [component] The Link Hub is how an operator FINDS a page. /benchmarks shipped
# public and correct and with nothing anywhere linking to it — reachable only by
# typing the URL — which is the state this guard exists to keep closed.
class AdminHubBenchmarksLinkTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) } # admin — the hub is admin-gated

  test "the hub links to the public benchmarks board" do
    get admin_hub_path

    assert_response :success
    assert_select "a[href=?]", benchmarks_path, count: 1
  end

  test "the tile says the page is the public one" do
    get admin_hub_path

    tile = css_select("a[href='#{benchmarks_path}']").first.text.squish
    assert_match(/Turf Score Benchmarks/, tile)
    assert_match(/Public/i, tile, "an operator should know this is what players read")
  end
end
