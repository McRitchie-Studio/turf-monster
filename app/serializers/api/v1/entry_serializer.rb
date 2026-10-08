# One entry as the agent API describes it: where it stands and what it picked.
#
# Used for the caller's own entries (GET /api/v1/entries) and for every row of a
# leaderboard, which is why visibility is decided here and not by the caller.
# WebRules#picks_visible? is the web's rule: a rival's picks stay hidden until
# the contest locks. When they are hidden `picks` is null, not an empty list, so
# "you may not see these yet" never reads as "this entry picked nothing".
#
# RANK AND PAYOUT HAVE A PROVISIONAL AND A FINAL FORM.
#   settled contest   rank is entries.rank and payout_cents is entries.payout_cents,
#                     both written by Contest#grade!. `final` is true.
#   anything else     rank is Ranking's tie-aware standing on current scores and
#                     payout_cents is null. Nothing has been won yet, and a
#                     number here would be read as money.
module Api
  module V1
    class EntrySerializer
      # writable: whether this caller may write at all right now (the account
      # hold and the age gate, ApiKeyAuthentication#write_refusal). It feeds
      # `editable`, so the field never promises an edit the server will refuse.
      def initialize(entry, contest:, facts:, board:, ranks:, web_rules:, viewer:, writable:)
        @entry = entry
        @writable = writable
        @contest = contest
        @facts = facts
        @board = board
        @ranks = ranks || {}
        @web_rules = web_rules
        @viewer = viewer
      end

      # The caller's own entry, in full.
      def as_json(*)
        {
          slug: entry.slug,
          contest: ContestSerializer.reference(contest, facts: facts),
          status: entry.status,
          entry_number: entry.entry_number,
          submitted_at: entry.created_at.iso8601,
          tx_signature: entry.onchain_tx_signature,
          editable: editable?
        }.merge(standing).merge(picks_fields)
      end

      # One leaderboard row. A rival's entry is named by its player, never by
      # its slug: GET /api/v1/entries/:slug only answers for the caller's own.
      def leaderboard_row
        mine = entry.user_id == @viewer.id
        {
          display_name: entry.user.display_name,
          mine: mine,
          entry_slug: mine ? entry.slug : nil
        }.merge(standing).merge(picks_fields)
      end

      private

      attr_reader :entry, :contest, :facts

      def standing
        final = contest.graded?
        {
          score: entry.score.to_f.round(1),
          rank: final ? entry.rank : @ranks[entry.id],
          payout_cents: final ? entry.payout_cents.to_i : nil,
          currency: ContestSerializer::CURRENCY,
          final: final
        }
      end

      def picks_fields
        return { picks_visible: false, picks: nil } if contest.retired_format? || !@web_rules.picks_visible?(entry, contest)

        picks = entry.selections.map { |selection| @board.pick(selection) }
        { picks_visible: true, picks: picks.sort_by { |pick| [pick[:rank] || Float::INFINITY, pick[:matchup_id]] } }
      end

      # What PATCH /api/v1/entries/:slug requires before it will replace picks
      # (Api::V1::Operations::EditEntry and Entry#update_picks!): a caller
      # who may write, an active entry, a Turf Totals contest that is open, not
      # cancelled, and not past its lock time. A pick whose own game has kicked
      # off is frozen on top of this; each pick says so in its own `locked`.
      def editable?
        @writable && entry.active? && !contest.retired_format? && contest.open? &&
          !contest.cancelled? && !facts.locked?(contest)
      end
    end
  end
end
