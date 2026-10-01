# The contests an agent can read: the list, one contest with its pickable
# teams, and its leaderboard (docs/AGENT_API.md). Read-only, so every action
# answers for a frozen account, as GET /api/v1/me does.
#
# VISIBILITY IS THE WEB'S.
#   list         open and settled contests, newest first, which is exactly
#                ContestsController#index. A `pending` contest (created, its
#                on-chain broadcast not yet verified) is never listed, to anyone.
#   one contest  ContestsController#set_contest: pending is a 404 unless the
#                key's player is an admin, who needs to open a stranded row.
#   cancelled    still listed and still readable, flagged `cancelled`. It keeps
#                `status: "open"` on the row, so the flag is the only tell.
#   rival picks  hidden until the contest locks (ContestsHelper#picks_visible_for?).
module Api
  module V1
    class ContestsController < BaseController
      include Pagination

      LISTED_STATUSES = %w[open settled].freeze

      def index
        statuses = listed_statuses
        return if performed?

        scope = Contest.where(status: statuses)
        contests = scope.includes(:slate).order(created_at: :desc, id: :desc)
                        .limit(page_limit).offset(page_offset).to_a

        render json: {
          contests: serialize_contests(contests),
          pagination: pagination_json(scope.count)
        }
      end

      def show
        contest = find_contest
        facts = ContestFacts.for([contest])
        board = Board.new(contest, contest_locked: facts.locked?(contest))

        render json: {
          contest: serialize_contests([contest], facts: facts).first,
          teams: contest.turf_totals? ? board.teams : []
        }
      end

      # Every confirmed entry, best first. Bounded by the contest's capacity in
      # practice; paged anyway, because an admin can set any capacity.
      def leaderboard
        contest = find_contest
        facts = ContestFacts.for([contest])
        reference = ContestSerializer.reference(contest, facts: facts)

        unless contest.turf_totals?
          return render json: { contest: reference, supported: false, note: ContestSerializer::SURVIVOR_NOTE,
                                entries: [], pagination: pagination_json(0) }
        end

        # Settled: the ranks Contest#grade! stored. Otherwise: the same tie rule
        # over current scores. Either way the ORDER is rank, then score, then id.
        ranks = Ranking.for_contests([contest.id]).fetch(contest.id, {})
        page_ids = leaderboard_order(contest, ranks).slice(page_offset, page_limit) || []
        entries = contest.entries.where(id: page_ids)
                         .includes(:user, :selections)
                         .index_by(&:id)

        board = Board.new(contest, contest_locked: facts.locked?(contest))
        web_rules = WebRules.new(current_user)
        writable = write_refusal.nil?
        rows = page_ids.filter_map { |id| entries[id] }.map do |entry|
          EntrySerializer.new(entry, contest: contest, facts: facts, board: board, ranks: ranks,
                                     web_rules: web_rules, viewer: current_user,
                                     writable: writable).leaderboard_row
        end

        render json: {
          contest: reference,
          supported: true,
          picks_hidden_until_lock: !facts.locked?(contest),
          entries: rows,
          pagination: pagination_json(ranks.size)
        }
      end

      private

      # ?status=open or ?status=settled narrows the list. Anything else is a
      # 400, not an empty list: `pending` in particular must not look like a
      # filter that happens to match nothing.
      def listed_statuses
        return LISTED_STATUSES if params[:status].nil? || params[:status] == ""
        return [params[:status]] if LISTED_STATUSES.include?(params[:status])

        render_api_error(:bad_request, "status must be one of: #{LISTED_STATUSES.join(', ')}.", status: :bad_request)
        nil
      end

      def find_contest
        scope = current_user.admin? ? Contest.all : Contest.where.not(status: :pending)
        scope.includes(:slate).find_by!(slug: slug_param)
      end

      def serialize_contests(contests, facts: ContestFacts.for(contests))
        ids = contests.map(&:id)
        entry_counts = Entry.confirmed.where(contest_id: ids).group(:contest_id).count
        my_counts = current_user.entries.confirmed.where(contest_id: ids).group(:contest_id).count
        web_rules = WebRules.new(current_user)
        writable = write_refusal.nil?

        contests.map do |contest|
          ContestSerializer.new(contest, facts: facts, web_rules: web_rules,
                                         entries_count: entry_counts[contest.id],
                                         my_entries_count: my_counts[contest.id],
                                         writable: writable).as_json
        end
      end

      # Ranking.for returns its hash in score-then-id order. A settled contest
      # is ordered by the stored rank instead, which is the same order unless a
      # score was touched after grading; the stored rank is the one that paid.
      def leaderboard_order(contest, provisional_ranks)
        return provisional_ranks.keys unless contest.settled?

        contest.entries.confirmed.order(Arel.sql("rank ASC NULLS LAST"), score: :desc, id: :asc).pluck(:id)
      end
    end
  end
end
