# The caller's own entries: read them, create one, replace its picks
# (docs/AGENT_API.md).
#
# WHICH ENTRIES. Confirmed ones: `active` (submitted, contest not graded) and
# `complete` (graded). That is Entry.confirmed, the same set the web counts
# toward leaderboards, the per-player limit and "contests I've entered".
#
# A `cart` entry is NOT served, and neither is an `abandoned` one. A cart is the
# website's half-built lineup, saved one tap at a time before the player pays.
# It has no score, no rank and no place on a leaderboard, and the API neither
# builds one nor touches the player's: an API entry is created whole, paid for
# in the same call, or not created at all (Entries::ApiSubmission).
#
# Another player's entry slug is a 404, the same answer as a slug that does not
# exist. Rivals are read through the contest leaderboard, under its own rule.
#
# THE WRITES. Both run behind the account hold (default-deny on every non-GET,
# ApiKeyAuthentication) and the age gate, asked again here because a key's
# stamp can predate the gate being switched on. Location is not re-asked: it
# was decided in the player's browser when the key was created.
module Api
  module V1
    class EntriesController < BaseController
      include Pagination

      before_action :require_age_verified, only: %i[create update]

      def index
        scope = current_user.entries.confirmed
        if params[:contest].present?
          contest = Contest.where.not(status: :pending).find_by!(slug: slug_param(:contest))
          scope = scope.where(contest_id: contest.id)
        end

        entries = scope.includes(:selections, contest: :slate)
                       .order(created_at: :desc, id: :desc)
                       .limit(page_limit).offset(page_offset).to_a

        render json: { entries: serialize(entries), pagination: pagination_json(scope.count) }
      end

      def show
        render json: { entry: serialize([find_entry]).first }
      end

      # POST /api/v1/contests/:slug/entries. Created and funded in one call or
      # not at all; the Idempotency-Key is what makes a retry safe.
      def create
        contest = find_contest
        key = idempotency_key
        matchup_ids = id_list_param(:matchup_ids)
        allow_usdc = boolean_param(:allow_usdc)

        result = Entries::ApiSubmission.new(
          user: current_user, api_key: current_api_key, contest: contest,
          matchup_ids: matchup_ids, allow_usdc: allow_usdc, idempotency_key: key,
          serializer: ->(entry) { serialize([load_entry(entry.id)]).first }
        ).call

        response.set_header("Retry-After", result.retry_after.to_s) if result.retry_after
        if result.error?
          return render json: { error: { code: result.error_code.to_s, message: result.message,
                                         retry_after: result.retry_after }.compact },
                        status: result.status
        end

        response.set_header("Idempotent-Replayed", "true") if result.replayed
        render json: result.body, status: result.status
      end

      # PATCH /api/v1/entries/:slug. Replaces the entry's picks. Not a spend:
      # the on-chain entry is a ticket with no picks in it, so this is a
      # database write and is naturally idempotent. Sending the same picks
      # twice is the same entry twice.
      def update
        entry = find_entry
        matchup_ids = id_list_param(:matchup_ids)
        contest = entry.contest

        refusal = update_refusal(entry, contest, matchup_ids)
        return render_api_error(refusal.code, refusal.message, status: :unprocessable_entity) if refusal

        render json: { entry: serialize([load_entry(entry.id)]).first }
      end

      private

      def confirmed_entries
        current_user.entries.confirmed.includes(:selections, contest: :slate)
      end

      def find_entry
        confirmed_entries.find_by!(slug: slug_param)
      end

      # A fresh load, so the response describes what is in the database now.
      def load_entry(id)
        confirmed_entries.find(id)
      end

      # The contest an entry is being made in: the web's visibility rule, as on
      # GET /api/v1/contests/:slug.
      def find_contest
        scope = current_user.admin? ? Contest.all : Contest.where.not(status: :pending)
        scope.includes(:slate).find_by!(slug: slug_param)
      end

      def idempotency_key
        key = request.headers["Idempotency-Key"]
        bad_request!("Send an Idempotency-Key header: a unique value for this entry, repeated on every retry.") if key.blank?
        bad_request!("Idempotency-Key must be 1 to 255 printable characters with no spaces.") unless key.match?(ApiEntryRequest::KEY_FORMAT)
        key
      end

      # Entry#update_picks! owns the rules (open, not locked, six pickable
      # teams, no team whose first game has kicked off added or dropped). Two
      # are added here, under the player's row lock so they cannot race a
      # second edit or a new entry: a cancelled contest is closed to edits, and
      # an edit may not turn this entry into a copy of another of the player's
      # own, which is the duplicate-lineup rule Entry#assert_enterable! applies
      # when an entry is made.
      def update_refusal(entry, contest, matchup_ids)
        current_user.with_lock do
          raise Entry::Refusal.new(:contest_cancelled, "This contest was cancelled.") if contest.cancelled?

          lineup = matchup_ids.uniq.sort
          twin = contest.entries.confirmed.where(user_id: current_user.id).where.not(id: entry.id)
                        .includes(:selections).any? { |other| other.selections.map(&:slate_matchup_id).sort == lineup }
          raise Entry::Refusal.new(:duplicate_lineup, "You already have an entry with this exact selection combination") if twin

          entry.update_picks!(matchup_ids)
        end
        nil
      rescue Entry::Refusal => e
        e
      end

      # One ContestFacts and one Ranking read for the whole page, and one Board
      # per distinct contest on it.
      def serialize(entries)
        contests = entries.map(&:contest).uniq
        facts = ContestFacts.for(contests)
        ranks = Ranking.for_contests(contests.reject(&:settled?).map(&:id))
        boards = contests.to_h { |contest| [contest.id, Board.new(contest, contest_locked: facts.locked?(contest))] }
        web_rules = WebRules.new(current_user)
        writable = write_refusal.nil?

        entries.map do |entry|
          EntrySerializer.new(entry, contest: entry.contest, facts: facts, board: boards[entry.contest_id],
                                     ranks: ranks[entry.contest_id], web_rules: web_rules,
                                     viewer: current_user, writable: writable).as_json
        end
      end
    end
  end
end
