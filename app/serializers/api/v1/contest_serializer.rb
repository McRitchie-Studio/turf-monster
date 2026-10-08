# One contest as the agent API describes it (docs/AGENT_API.md).
#
# Every fact comes from the model or from ContestFacts, which mirrors the model
# without its per-row queries. The counts are passed in, already grouped for the
# whole page, so a list of contests never counts entries one contest at a time.
#
# Money is integer cents. `currency` is "USD": entry fees are paid in USDC (one
# USDC is one dollar) or with a free entry token, and prizes are paid in USDC.
module Api
  module V1
    class ContestSerializer
      CURRENCY = "USD".freeze

      RETIRED_FORMAT_NOTE = "This contest ran a format Turf Monster no longer offers. " \
                            "It is listed as a record; its teams, picks and leaderboard " \
                            "are omitted. Its final standings are on the website.".freeze

      # contests.slates.sport is "nfl" or "fifa". The scoring column is named
      # `goals` for both; this is what it actually holds.
      SCORING_UNITS = { "nfl" => "points", "fifa" => "goals" }.freeze

      # writable: whether this caller may write at all right now (the account
      # hold and the age gate, ApiKeyAuthentication#write_refusal). It feeds
      # `accepting_entries`, so the field never promises an entry the server
      # will refuse.
      def initialize(contest, facts:, web_rules:, entries_count:, my_entries_count:, writable:)
        @contest = contest
        @writable = writable
        @facts = facts
        @web_rules = web_rules
        @entries_count = entries_count.to_i
        @my_entries_count = my_entries_count.to_i
      end

      def as_json(*)
        summary.merge(supported ? {} : { note: RETIRED_FORMAT_NOTE })
      end

      # The short form embedded in an entry.
      def self.reference(contest, facts:)
        {
          slug: contest.slug,
          name: contest.name,
          game_type: contest.game_type,
          phase: facts.phase(contest),
          locked: facts.locked?(contest),
          live: facts.live?(contest),
          settled: contest.graded?,
          cancelled: contest.cancelled?,
          locks_at: facts.locks_at(contest)&.iso8601
        }
      end

      def self.sport(contest)
        contest.slate&.sport
      end

      private

      attr_reader :contest, :facts

      def supported
        !contest.retired_format?
      end

      def summary
        locked = facts.locked?(contest)
        spots_left = @web_rules.spots_left(contest, @entries_count)
        sport = self.class.sport(contest)

        {
          slug: contest.slug,
          name: contest.name,
          tagline: contest.tagline,
          game_type: contest.game_type,
          supported: supported,
          sport: sport,
          scoring_unit: SCORING_UNITS[sport],
          status: contest.status,
          phase: facts.phase(contest),
          locked: locked,
          live: facts.live?(contest),
          settled: contest.graded?,
          cancelled: contest.cancelled?,
          coming_soon: contest.coming_soon?,
          accepting_entries: accepting_entries?(locked, spots_left),
          locks_at: facts.locks_at(contest)&.iso8601,
          concludes_at: contest.concludes_at&.iso8601,
          currency: CURRENCY,
          entry_fee_cents: contest.entry_fee_cents,
          guaranteed_prize_cents: contest.guaranteed_prize_cents,
          payouts: contest.payouts.sort.map { |rank, cents| { rank: rank, payout_cents: cents } },
          max_entries: contest.max_entries || contest.format_config[:max_entries],
          entries_count: @entries_count,
          spots_left: spots_left,
          picks_required: facts.picks_required(contest),
          max_entries_per_player: contest.max_entries_per_user,
          my_entries_count: @my_entries_count,
          multi_week: facts.multi_week?(contest),
          games_per_team: facts.games_per_team(contest),
          weeks: contest.week_span_label
        }
      end

      # Whether POST /api/v1/contests/:slug/entries would get past its gates
      # right now: a contest the API can enter (Turf Totals), open, not locked,
      # not cancelled, not marked coming soon, with room left and room under
      # this player's own limit, for a caller who may write (not on hold, age
      # verified when the gate is on). It does not speak for the wallet: whether
      # there is a token to spend, or a wallet the server can sign for, is on
      # GET /api/v1/me.
      def accepting_entries?(locked, spots_left)
        @writable && supported && contest.open? && !locked && !contest.cancelled? && !contest.coming_soon? &&
          spots_left.positive? && @my_entries_count < contest.max_entries_per_user
      end
    end
  end
end
