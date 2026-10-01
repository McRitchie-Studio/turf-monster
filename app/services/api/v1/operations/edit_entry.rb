# PATCH /api/v1/entries/:slug, and the MCP tool `edit_entry`: replace an
# entry's picks. Not a spend: the on-chain entry is a ticket with no picks in
# it, so this is a database write and is naturally idempotent. Sending the same
# picks twice is the same entry twice.
module Api
  module V1
    module Operations
      class EditEntry < Base
        def call
          entry = find_entry
          matchup_ids = id_list_param(:matchup_ids)

          refusal = update_refusal(entry, entry.contest, matchup_ids)
          return Outcome.error(refusal.code, refusal.message, status: :unprocessable_entity) if refusal

          ok(entry: serialize_entries([load_entry(entry.id)]).first)
        end

        private

        # Entry#update_picks! owns the rules (open, not locked, six pickable
        # teams, no team whose first game has kicked off added or dropped). Two
        # are added here, under the player's row lock so they cannot race a
        # second edit or a new entry: a cancelled contest is closed to edits, and
        # an edit may not turn this entry into a copy of another of the player's
        # own, which is the duplicate-lineup rule Entry#assert_enterable! applies
        # when an entry is made.
        def update_refusal(entry, contest, matchup_ids)
          user.with_lock do
            raise Entry::Refusal.new(:contest_cancelled, "This contest was cancelled.") if contest.cancelled?

            lineup = matchup_ids.uniq.sort
            twin = contest.entries.confirmed.where(user_id: user.id).where.not(id: entry.id)
                          .includes(:selections).any? { |other| other.selections.map(&:slate_matchup_id).sort == lineup }
            raise Entry::Refusal.new(:duplicate_lineup, "You already have an entry with this exact selection combination") if twin

            entry.update_picks!(matchup_ids)
          end
          nil
        rescue Entry::Refusal => e
          e
        end
      end
    end
  end
end
