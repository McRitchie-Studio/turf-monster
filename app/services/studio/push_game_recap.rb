require "net/http"
require "json"

module Studio
  # Posts ONE finished game to the McRitchie Studio hub, which turns it into a
  # content idea ("Bills Beat Dolphins 24-17") at the head of the faceless
  # social pipeline.
  #
  # This is the only thing turf-monster tells the hub about a game. The hub
  # never reads this database; the whole crossing is this one request.
  #
  # The hub endpoint is idempotent — it answers 201 when the call created the
  # recap and 200 when the recap already existed — which matters because
  # `Nfl::LiveScores::PollCycle` is safe to re-run by design and a Sidekiq retry
  # can deliver the same final twice. Neither end has to deduplicate in memory.
  class PushGameRecap
    class Error < StandardError; end

    DEFAULT_BASE_URL = "https://mcritchie.studio".freeze
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10

    # The hub push is optional infrastructure. A stack with no shared secret —
    # a developer's laptop, a review app — should run the scoring cycle exactly
    # as it always did rather than fail or log noise on every final.
    def self.configured?
      ENV["AGENT_API_SECRET"].present?
    end

    def initialize(game, base_url: nil, secret: nil)
      @game = game
      @base_url = (base_url || ENV["STUDIO_API_BASE"].presence || DEFAULT_BASE_URL).chomp("/")
      @secret = secret || ENV["AGENT_API_SECRET"]
    end

    def call
      raise Error, "AGENT_API_SECRET not set" if @secret.blank?

      post_recap(authenticate)
    end

    private

    attr_reader :game

    def authenticate
      response = post_json("/api/v1/auth", { secret: @secret }, token: nil)
      token = response["token"]
      raise Error, "no token in auth response" if token.blank?

      token
    end

    def post_recap(token)
      post_json("/api/v1/game_recaps", { game: payload }, token: token)
    end

    def payload
      {
        game_slug:      game.slug,
        home_team_slug: game.home_team_slug,
        away_team_slug: game.away_team_slug,
        home_score:     game.home_score.to_i,
        away_score:     game.away_score.to_i,
        status_detail:  game.status_detail,
        season_year:    game.season_year,
        season_type:    game.season_type,
        week:           game.week,
        kickoff_at:     game.kickoff_at&.iso8601
      }.compact
    end

    def post_json(path, body, token:)
      uri = URI("#{@base_url}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{token}" if token

      request.body = body.to_json

      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "studio #{path} returned #{response.code}: #{response.body.to_s[0, 200]}"
      end

      JSON.parse(response.body.to_s)
    rescue JSON::ParserError => e
      # Never echo the body — this request carries the shared secret, and the
      # auth call's body IS the secret.
      raise Error, "studio #{path} returned unparseable JSON (#{e.class})"
    end
  end
end
