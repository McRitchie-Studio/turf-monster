require "test_helper"

# [unit] The ESPN HTTP client.
#
# This file exists because its absence had already cost us once. The client's
# own comment records that `Nfl::FetchHistoricalScores` sat broken in main —
# 403 on every call — because it sent no User-Agent and nothing tested the
# network path; its only test covered the pure parse seam, which cannot see a
# transport failure. These tests cover the transport.
class Nfl::Espn::ClientTest < ActiveSupport::TestCase
  # A stand-in for Net::HTTP that records what the client asked for and returns
  # whatever response the test wants. Real Net::HTTPResponse objects, so the
  # `is_a?(Net::HTTPSuccess)` check in get_json is exercised for real.
  def with_http(response)
    captured = {}
    http = Object.new
    http.define_singleton_method(:get) do |path, headers = {}|
      captured[:path] = path
      captured[:headers] = headers
      response
    end

    Net::HTTP.stub(:start, ->(*_args, **_kw, &blk) { blk.call(http) }) do
      yield captured
    end
    captured
  end

  def response(klass, code, body, content_type: "application/json")
    r = klass.new("1.1", code, "")
    r["content-type"] = content_type
    r.instance_variable_set(:@read, true)
    r.instance_variable_set(:@body, body)
    r
  end

  def ok(body, **opts) = response(Net::HTTPOK, "200", body, **opts)

  # THE REGRESSION THAT ALREADY HAPPENED ONCE.
  #
  # ESPN's edge refuses Ruby's default agent with a 403. Measured against the
  # live endpoint: no header -> 403, a custom "TurfMonster/1.0" -> 403, a Chrome
  # string from Ruby -> 403, "curl/8.7.1" -> 200. Drop this header and every
  # call in the feature fails identically, with no other test able to see it.
  test "sends a User-Agent the edge accepts" do
    captured = with_http(ok('{"events":[]}')) { Nfl::Espn::Client.new.scoreboard }

    assert_equal Nfl::Espn::Client::USER_AGENT, captured[:headers]["User-Agent"]
    refute_empty captured[:headers]["User-Agent"].to_s,
      "an absent agent is the exact shape that broke FetchHistoricalScores"
  end

  test "asks for the season slot it was given" do
    captured = with_http(ok('{"events":[]}')) do
      Nfl::Espn::Client.new.scoreboard(year: 2026, season_type: 1, week: 4)
    end

    assert_includes captured[:path], "dates=2026"
    assert_includes captured[:path], "seasontype=1"
    assert_includes captured[:path], "week=4"
  end

  test "a bare scoreboard request asks for no slot at all" do
    captured = with_http(ok('{"events":[]}')) { Nfl::Espn::Client.new.scoreboard }

    refute_includes captured[:path], "seasontype"
    refute_includes captured[:path], "week="
  end

  test "summary addresses one event" do
    captured = with_http(ok("{}")) { Nfl::Espn::Client.new.summary(event_id: "401873298") }

    assert_includes captured[:path], "/summary"
    assert_includes captured[:path], "event=401873298"
  end

  test "parses a JSON body" do
    with_http(ok('{"events":[{"id":"1"}]}')) do
      payload = Nfl::Espn::Client.new.scoreboard
      assert_equal "1", payload.dig("events", 0, "id")
    end
  end

  # The 403 arrives as an HTML error page with a 403 status. Checking the status
  # names the real problem instead of surfacing a JSON::ParserError pointing at
  # "<HTML><HEAD>".
  test "a 403 raises a client error naming the status" do
    with_http(response(Net::HTTPForbidden, "403", "<HTML>Access Denied</HTML>", content_type: "text/html")) do
      error = assert_raises(Nfl::Espn::Client::Error) { Nfl::Espn::Client.new.scoreboard }
      assert_match(/403/, error.message)
    end
  end

  # A 200 carrying HTML is the shape an edge error takes when it does not bother
  # with a status. Content type is checked BEFORE parsing so the message says
  # what arrived rather than where the parser gave up.
  test "a 200 carrying HTML raises rather than reaching the parser" do
    with_http(ok("<HTML><HEAD>", content_type: "text/html")) do
      error = assert_raises(Nfl::Espn::Client::Error) { Nfl::Espn::Client.new.scoreboard }
      assert_match(/not JSON/i, error.message)
    end
  end

  test "a JSON content type carrying garbage raises a client error, not a parser error" do
    with_http(ok("{not json")) do
      error = assert_raises(Nfl::Espn::Client::Error) { Nfl::Espn::Client.new.scoreboard }
      assert_match(/unparseable/i, error.message)
    end
  end

  # Every transport failure has to arrive as ONE error class, because the poll
  # cycle backs off on Client::Error and treats anything else as a bug.
  test "a network failure is raised as a client error" do
    Net::HTTP.stub(:start, ->(*_a, **_k) { raise Errno::ECONNREFUSED }) do
      assert_raises(Nfl::Espn::Client::Error) { Nfl::Espn::Client.new.scoreboard }
    end
  end

  test "a timeout is raised as a client error" do
    Net::HTTP.stub(:start, ->(*_a, **_k) { raise Timeout::Error }) do
      assert_raises(Nfl::Espn::Client::Error) { Nfl::Espn::Client.new.scoreboard }
    end
  end
end
