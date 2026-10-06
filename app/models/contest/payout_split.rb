class Contest
  # Who is paid what when a contest grades, as a pure function of the finishing
  # order and the contest's payout table.
  #
  # Entries arrive in finishing order: score descending, then entry id
  # ascending, so the earliest entry leads every group of equal scores. Tied
  # entries share a rank and the next rank is skipped (1, 1, 3).
  #
  # The number of paid entries never exceeds the number of paid ranks, which is
  # what keeps every contest inside one settle transaction:
  #
  #   - A tie inside the paid ranks pools the prizes of the places it covers and
  #     splits them evenly; any remainder cent goes to the earliest entries.
  #   - A tie that reaches past the last paid rank pays only as many entries as
  #     there are paid places left, earliest entries first, and those entries
  #     split the prizes of the places they cover. A tie exactly at the last
  #     paid rank therefore pays the earliest entry the last prize alone.
  #
  # turf-vault's settle_contest checks only that the payouts sum to no more than
  # the prize pool, so this rule needs no change on chain.
  module PayoutSplit
    module_function

    # scores:  the entries' scores in finishing order.
    # payouts: { rank => cents }.
    # Returns one [rank, cents] pair per score, in the same order.
    def call(scores, payouts)
      paid_places = payouts.keys.max || 0
      result = []

      scores.chunk_while { |a, b| a == b }.each do |group|
        rank = result.size + 1
        paid_in_group = (paid_places - rank + 1).clamp(0, group.size)
        prize = (rank...(rank + paid_in_group)).sum { |place| payouts[place] || 0 }

        group.each_index do |i|
          cents = 0
          if i < paid_in_group
            cents = prize / paid_in_group
            cents += 1 if i < prize % paid_in_group
          end
          result << [rank, cents]
        end
      end

      result
    end
  end
end
