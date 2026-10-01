# One agent API operation: what an endpoint DOES, with no HTTP in it.
#
# Every /api/v1 action and every MCP tool (docs/AGENT_API.md) is one of these.
# The REST controller hands it the request's params and renders the Outcome as
# a response; the MCP endpoint hands it a tool's arguments and renders the same
# Outcome as a tool result. Neither holds a rule of its own, so the two
# surfaces cannot drift: there is one place a query, a visibility rule or a
# parameter check lives.
#
#   Api::V1::Operations::GetContest.call(user:, api_key:, params: { slug: "…" }, writable: true)
#     # => Outcome(status: :ok, body: { contest: …, teams: […] })
#
# An operation answers three ways, the same three the REST surface always had:
#
#   an Outcome                      a success, or a refusal with a code
#   ActiveRecord::RecordNotFound    no such contest or entry (REST: 404)
#   ActionController::BadRequest    a parameter of the wrong shape (REST: 400)
#
# The two exceptions are turned into the envelope by the caller, through
# ApiKeyAuthentication#api_exception_refusal, so both surfaces word them alike.
#
# WHAT IS NOT HERE: authentication and the write gates (account hold, age).
# Those are questions about the REQUEST and stay in ApiKeyAuthentication. A
# surface asks them before it calls a writing operation, and passes the answer
# in as `writable`, which only colours what the serializers say (`editable`,
# `accepting_entries`).
module Api
  module V1
    module Operations
      class Base
        include Pagination # and StrictParams: the parameter readers, over #params

        def self.call(...)
          new(...).call
        end

        # params: anything that answers [] by name: ActionController::Parameters
        # from REST, a HashWithIndifferentAccess of tool arguments from MCP.
        def initialize(user:, params:, api_key: nil, writable: true)
          @user = user
          @api_key = api_key
          @params = params
          @writable = writable
        end

        private

        attr_reader :user, :api_key, :params, :writable

        # ok(contest: …, teams: …): the keywords ARE the response body.
        def ok(**body)
          Outcome.ok(body)
        end

        # The web's visibility rule for one contest (ContestsController#set_contest):
        # `pending` is a 404 unless the player is an admin.
        def find_contest(name = :slug)
          scope = user.admin? ? Contest.all : Contest.where.not(status: :pending)
          scope.includes(:slate).find_by!(slug: slug_param(name))
        end

        def confirmed_entries
          user.entries.confirmed.includes(:selections, contest: :slate)
        end

        def find_entry
          confirmed_entries.find_by!(slug: slug_param)
        end

        # A fresh load, so the answer describes what is in the database now.
        def load_entry(id)
          confirmed_entries.find(id)
        end

        def serialize_contests(contests, facts: ContestFacts.for(contests))
          ids = contests.map(&:id)
          entry_counts = Entry.confirmed.where(contest_id: ids).group(:contest_id).count
          my_counts = user.entries.confirmed.where(contest_id: ids).group(:contest_id).count
          web_rules = WebRules.new(user)

          contests.map do |contest|
            ContestSerializer.new(contest, facts: facts, web_rules: web_rules,
                                           entries_count: entry_counts[contest.id],
                                           my_entries_count: my_counts[contest.id],
                                           writable: writable).as_json
          end
        end

        # One ContestFacts and one Ranking read for the whole page, and one Board
        # per distinct contest on it.
        def serialize_entries(entries)
          contests = entries.map(&:contest).uniq
          facts = ContestFacts.for(contests)
          ranks = Ranking.for_contests(contests.reject(&:settled?).map(&:id))
          boards = contests.to_h { |contest| [contest.id, Board.new(contest, contest_locked: facts.locked?(contest))] }
          web_rules = WebRules.new(user)

          entries.map do |entry|
            EntrySerializer.new(entry, contest: entry.contest, facts: facts, board: boards[entry.contest_id],
                                       ranks: ranks[entry.contest_id], web_rules: web_rules,
                                       viewer: user, writable: writable).as_json
          end
        end
      end
    end
  end
end
