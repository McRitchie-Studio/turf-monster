require "test_helper"

# [unit] The payload turf-monster sends the hub about a finished game, and the
# refusals around it. Only the TRANSPORT is stubbed — the real service builds
# the payload, sequences auth before the post, and raises its own errors.
class Studio::PushGameRecapTest < ActiveSupport::TestCase
  setup do
    @game = games(:past_game)
    @game.update!(home_score: 24, away_score: 17, status_detail: "Final",
                  season_year: 2026, season_type: 2, week: 3)
  end

  # Replaces only `post_json`, recording each call, so everything above the
  # socket is the real object.
  def recorder_for(service, recap_response: { "data" => { "slug" => "content-abc" } })
    calls = []
    service.define_singleton_method(:post_json) do |path, body, token:|
      calls << { path: path, body: body, token: token }
      path == "/api/v1/auth" ? { "token" => "tok-123" } : recap_response
    end
    calls
  end

  test "configured? follows the shared secret" do
    ENV["AGENT_API_SECRET"] = "s"
    assert Studio::PushGameRecap.configured?

    ENV.delete("AGENT_API_SECRET")
    assert_not Studio::PushGameRecap.configured?
  ensure
    ENV.delete("AGENT_API_SECRET")
  end

  test "authenticates first, then posts the recap with the returned token" do
    service = Studio::PushGameRecap.new(@game, secret: "shh")
    calls = recorder_for(service)

    service.call

    assert_equal ["/api/v1/auth", "/api/v1/game_recaps"], calls.map { |c| c[:path] }
    assert_nil calls.first[:token], "the auth call cannot carry a token it does not have yet"
    assert_equal "tok-123", calls.last[:token]
  end

  test "sends the scoreline and the slugs the hub keys on" do
    service = Studio::PushGameRecap.new(@game, secret: "shh")
    calls = recorder_for(service)

    service.call
    payload = calls.last[:body][:game]

    # The slug is DERIVED (<home>-vs-<away>) by the Sluggable concern, so assert
    # against the record rather than pinning the literal the fixture was written with.
    assert_equal @game.reload.slug, payload[:game_slug]
    assert_equal "team-a-vs-team-b", payload[:game_slug]
    assert_equal "team-a",    payload[:home_team_slug]
    assert_equal "team-b",    payload[:away_team_slug]
    assert_equal 24, payload[:home_score]
    assert_equal 17, payload[:away_score]
    assert_equal "Final", payload[:status_detail]
    assert_equal 3, payload[:week]
  end

  test "refuses without a secret rather than calling out unauthenticated" do
    service = Studio::PushGameRecap.new(@game, secret: "")
    calls = recorder_for(service)

    assert_raises Studio::PushGameRecap::Error do
      service.call
    end
    assert_empty calls, "nothing should reach the network without a secret"
  end

  test "raises when auth returns no token" do
    service = Studio::PushGameRecap.new(@game, secret: "shh")
    service.define_singleton_method(:post_json) { |*, **| {} }

    error = assert_raises Studio::PushGameRecap::Error do
      service.call
    end
    assert_match "no token", error.message
  end

  test "base_url override is honoured over the default" do
    service = Studio::PushGameRecap.new(@game, base_url: "http://localhost:3000/", secret: "shh")

    assert_equal "http://localhost:3000", service.instance_variable_get(:@base_url)
  end
end
