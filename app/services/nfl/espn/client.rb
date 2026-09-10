require "net/http"
require "json"

module Nfl
  module Espn
    # HTTP access to ESPN's public NFL endpoints. No key, no auth, no account —
    # but not without a catch, documented on USER_AGENT below.
    #
    # Two endpoints carry this whole feature:
    #
    #   scoreboard  — EVERY game in a week, in ONE request. 16 games arrive in
    #                 ~220 KB raw / ~18 KB gzipped, and the cost does not change
    #                 with how many games are being played. This is why polling
    #                 a full Sunday slate is one request per cycle, not one per
    #                 game.
    #   summary     — ONE game's scoring plays, ~628 KB. Called only for a game
    #                 whose score actually moved, which across eight concurrent
    #                 games averages well under one call per 30-second cycle.
    class Client
      BASE_URL = "https://site.api.espn.com/apis/site/v2/sports/football/nfl".freeze

      # DO NOT "fix" this to a polite custom agent, and do not remove it.
      #
      # ESPN's edge refuses Ruby. Measured directly against the live endpoint:
      #
      #   no User-Agent header (Net::HTTP's default)  -> 403 Access Denied
      #   "TurfMonster/1.0 (+https://turfmonster.io)" -> 403 Access Denied
      #   "Mozilla/5.0 ... Chrome/128 ..."            -> 403 Access Denied
      #   "curl/8.7.1"                                -> 200 application/json
      #   "python-requests/2.32"                      -> 200 application/json
      #
      # Note the third line: sending a *browser* string from Ruby is refused
      # too, even with the full complement of Accept / Accept-Language /
      # Referer / sec-ch-ua headers. The edge checks the agent against the
      # client's actual fingerprint, so the only strings that work are the ones
      # belonging to scripted HTTP clients — which is honestly what we are.
      #
      # This is also why `Nfl::FetchHistoricalScores` sat broken: it sent no
      # agent at all, and its test only exercised the pure parse seam, so CI
      # never saw the 403.
      USER_AGENT = "curl/8.7.1".freeze

      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 15

      # Raised for anything the caller cannot parse as a scoreboard. The poller
      # catches this and backs off rather than dying — a feed we do not own will
      # have bad minutes, and a bad minute must not end a twelve-hour run.
      class Error < StandardError; end

      def self.scoreboard(...) = new.scoreboard(...)
      def self.summary(...) = new.summary(...)

      # One week of games. Passing no slot returns whatever ESPN considers
      # current, which is what a plain scoreboard request does.
      def scoreboard(year: nil, season_type: nil, week: nil)
        params = {}
        params[:dates] = year if year
        params[:seasontype] = season_type if season_type
        params[:week] = week if week
        params[:limit] = 400

        get_json("/scoreboard", params)
      end

      # One game's detail, including its scoringPlays.
      def summary(event_id:)
        get_json("/summary", { event: event_id })
      end

      private

      def get_json(path, params)
        uri = URI("#{BASE_URL}#{path}")
        uri.query = URI.encode_www_form(params) if params.any?

        response = perform(uri)

        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "ESPN #{path} returned HTTP #{response.code}"
        end

        # A 403 from the edge arrives as an HTML error page. Checking the
        # content type BEFORE parsing turns that into a clear "ESPN returned
        # text/html" instead of a JSON::ParserError pointing at "<HTML><HEAD>".
        unless response.content_type.to_s.include?("json")
          raise Error, "ESPN #{path} returned #{response.content_type.inspect}, not JSON"
        end

        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise Error, "ESPN #{path} returned unparseable JSON: #{e.message}"
      rescue Timeout::Error, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
        raise Error, "ESPN #{path} request failed: #{e.class}: #{e.message}"
      end

      # Net::HTTP advertises gzip and inflates the response itself, which is
      # what turns a 220 KB scoreboard into ~18 KB on the wire. We get that for
      # free precisely because we do NOT set Accept-Encoding by hand — doing so
      # would switch off the automatic decompression.
      def perform(uri)
        Net::HTTP.start(
          uri.host, uri.port,
          use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT
        ) do |http|
          http.get(uri.request_uri, { "User-Agent" => USER_AGENT })
        end
      end
    end
  end
end
