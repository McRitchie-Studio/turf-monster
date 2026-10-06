require "test_helper"

# [integration] Rack::Deflater on the real stack (lib/response_compression.rb):
# a page and a JSON endpoint come back gzipped to a client that asks, plain to
# one that does not, a tiny response stays plain, and a conditional GET still
# answers 304.
class ResponseCompressionIntegrationTest < ActionDispatch::IntegrationTest
  include AgentApiTestSupport

  GZIP = { "Accept-Encoding" => "gzip, deflate, br" }.freeze

  def inflate(bytes)
    ActiveSupport::Gzip.decompress(bytes)
  end

  test "the v2 page is gzipped for a client that accepts it and inflates to the page" do
    get turf_monster_v2_path, headers: GZIP

    assert_response :success
    assert_equal "gzip", response.headers["Content-Encoding"]
    assert_includes response.headers["Vary"].to_s, "Accept-Encoding"

    html = inflate(response.body)
    assert html.start_with?("<!DOCTYPE html>"), "the inflated body must be the HTML document"
    assert_includes html, 'data-test="turf-monster-v2"'
    # 715 KB -> 244 KB in test; production measured 1,039,915 -> 268,981 (gzip -6).
    assert_operator response.body.bytesize * 2, :<, html.bytesize, "gzip should at least halve the page"
  end

  test "the v2 page is plain for a client that sends no Accept-Encoding" do
    get turf_monster_v2_path

    assert_response :success
    assert_nil response.headers["Content-Encoding"]
    assert_includes response.body, 'data-test="turf-monster-v2"'
    assert_equal response.body.bytesize, response.headers["Content-Length"].to_i
  end

  def api_headers(extra = {})
    @key ||= mint_api_key(users(:jordan))
    GZIP.merge("User-Agent" => AGENT_UA, "Authorization" => "Bearer #{@key.raw_token}").merge(extra)
  end

  test "a JSON endpoint is gzipped" do
    contest = contests(:one)
    get api_v1_contest_path(contest.slug), headers: api_headers

    assert_response :success
    assert_equal "gzip", response.headers["Content-Encoding"]
    assert_equal contest.slug, JSON.parse(inflate(response.body)).dig("contest", "slug")
  end

  test "a tiny response is not compressed" do
    get rails_health_check_path, headers: GZIP

    assert_response :success
    assert_operator response.body.bytesize, :<, ResponseCompression::MIN_BYTES
    assert_nil response.headers["Content-Encoding"]
  end

  # The v2 page's body changes per request (CSRF token), so its ETag never
  # repeats; the contest JSON is deterministic. The ETag is computed on the
  # identity body, inside Deflater, so it is the same for both encodings.
  test "a conditional GET still answers 304 with the ETag of a gzipped response" do
    path = api_v1_contest_path(contests(:one).slug)
    get path, headers: api_headers
    assert_equal "gzip", response.headers["Content-Encoding"]
    etag = response.headers["ETag"]
    assert etag.present?, "the response must carry an ETag"

    get path, headers: api_headers("If-None-Match" => etag)

    assert_response :not_modified
    assert_nil response.headers["Content-Encoding"]
    assert_empty response.body
  end
end
