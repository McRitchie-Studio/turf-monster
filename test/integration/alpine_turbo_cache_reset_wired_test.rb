require "test_helper"

# [component] Proof the Alpine/Turbo cache reset is actually ON THE PAGE.
#
# test/views/alpine_turbo_cache_reset_test.rb asserts the partial's contents,
# which is necessary and not sufficient: it renders the partial directly, so it
# stays green even if the application layout stops rendering it. That is the
# exact failure this fix is most exposed to — one deleted render line, no test
# red anywhere, and the duplicate-pick-slots bug silently returns to production.
#
# So this asserts the seam instead of the part: fetch a REAL page through the
# real layout and require the sweep to be in the response body.
class AlpineTurboCacheResetWiredTest < ActionDispatch::IntegrationTest
  # The guard flag is the partial's unique fingerprint — it appears nowhere else
  # in the app, so finding it in a response means that partial rendered.
  MARKER = "__turfAlpineTurboCacheReset".freeze

  test "the application layout ships the sweep to a signed-out visitor" do
    get root_path
    # `/` redirects to the main contest (SeasonConfig.main_contest).
    follow_redirect! while response.redirect?
    assert_response :success

    assert_includes response.body, MARKER,
                    "the layout must render shared/_alpine_turbo_cache_reset — " \
                    "without it Turbo caches Alpine's generated rows and a Back " \
                    "navigation renders them twice"
    assert_includes response.body, "turbo:before-cache",
                    "the sweep must be armed on the event Turbo snapshots on"
  end

  test "the sweep reaches the contest board, where the bug was reported" do
    get contest_path(contests(:one))
    assert_response :success

    assert_includes response.body, MARKER,
                    "the picks sidebar is the surface the operator saw doubled"
  end

  test "the guard flag is unique, so the marker above proves what it claims" do
    hits = Dir.glob(Rails.root.join("app/**/*.erb")).select do |path|
      File.read(path).include?(MARKER)
    end

    assert_equal 1, hits.length,
                 "#{MARKER} must name exactly one partial or the wiring " \
                 "assertions above stop being evidence — found: #{hits.inspect}"
  end
end
