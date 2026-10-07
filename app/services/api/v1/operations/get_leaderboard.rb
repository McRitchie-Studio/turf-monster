# GET /api/v1/contests/:slug/leaderboard, and the MCP tool `get_leaderboard`:
# every confirmed entry, best first. Bounded by the contest's capacity in
# practice; paged anyway, because an admin can set any capacity. Rival picks
# stay hidden until the contest locks (ContestsHelper#picks_visible_for?).
module Api
  module V1
    module Operations
      class GetLeaderboard < Base
        def call
          contest = find_contest
          facts = ContestFacts.for([contest])
          reference = ContestSerializer.reference(contest, facts: facts)

          if contest.retired_format?
            return ok(contest: reference, supported: false, note: ContestSerializer::RETIRED_FORMAT_NOTE,
                      entries: [], pagination: pagination_json(0))
          end

          # Settled: the ranks Contest#grade! stored. Otherwise: the same tie rule
          # over current scores. Either way the ORDER is rank, then score, then id.
          ranks = Ranking.for_contests([contest.id]).fetch(contest.id, {})

          ok(contest: reference,
             supported: true,
             picks_hidden_until_lock: !facts.locked?(contest),
             entries: rows(contest, facts, ranks),
             pagination: pagination_json(ranks.size))
        end

        private

        def rows(contest, facts, ranks)
          page_ids = leaderboard_order(contest, ranks).slice(page_offset, page_limit) || []
          entries = contest.entries.where(id: page_ids).includes(:user, :selections).index_by(&:id)
          board = Board.new(contest, contest_locked: facts.locked?(contest))
          web_rules = WebRules.new(user)

          page_ids.filter_map { |id| entries[id] }.map do |entry|
            EntrySerializer.new(entry, contest: contest, facts: facts, board: board, ranks: ranks,
                                       web_rules: web_rules, viewer: user,
                                       writable: writable).leaderboard_row
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
end
