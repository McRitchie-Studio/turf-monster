module SlatesHelper
  # Every price the admin board can display, computed in Ruby.
  #
  # The board used to recompute the curve in JavaScript so its slider could
  # preview a scale Ruby had no parameter for. Two implementations, two rounding
  # rules — and "Save Multipliers" posts the text on screen, so the page could
  # persist a price the curve never produced. The page now LOOKS UP a price.
  #
  # Shape: { "2.5" => { "1.0" => [rank1, rank2, …], "1.5" => [...] } }.
  #
  # THE KEYS ARE A CONTRACT WITH JAVASCRIPT, and getting them wrong is worse
  # than the rounding bug this replaced: a miss returns null for EVERY row, and
  # a drag-reorder then saves each team's old price against its new rank.
  # `_fcMult` derives its key with `toFixed(1)`, which rounds the exact binary
  # double half-up; Ruby's `format("%.1f", x)` rounds half-to-EVEN, so the two
  # disagree on a tie — `format("%.1f", 1.25)` is "1.2" while `(1.25).toFixed(1)`
  # is "1.3", and 1.25 is the bye factor of a five-week span. Rounding FIRST with
  # `Float#round` (half away from zero) agrees with `toFixed` on every value
  # either side can hold here; `price_key` is the single place that happens.
  # Defined on the MODEL, beside the curve it parameterizes, so the price table
  # here and the band SlatesController#update_turf_scores accepts back cannot
  # drift apart. Aliased rather than moved outright: this is the name the view
  # and this file's tests already read.
  SLIDER_SCALES = SlateMatchup::SLIDER_SCALES

  # The one rule both languages must agree on. Also the reason the view seeds
  # the slider from a value already rounded to one decimal: the page can then
  # only ever hold a scale this table has a key for.
  def price_key(value)
    format("%.1f", value.to_f.round(1))
  end

  # `resolved_scale` is the slate's own `formula_mult_scale` — where the page
  # STARTS, before the slider is touched. It is not a slider position: the admin
  # formula field steps by 0.1, so 8 of every 10 values it offers are off the
  # slider's half-step grid and would key to a row that does not exist.
  def turf_score_scale_table(slate:, teams:, factors:, resolved_scale: nil)
    return {} if teams.to_i < 1

    # A NEGATIVE SCALE IS NOT A BOARD, so the table does not draw one. The curve
    # is (1.0 + scale * curve) * game_factor, so a scale below zero prices the
    # WORST team lowest — on a 32-team NFL slate at scale -5.0 the rows run down
    # to x-4.0, and at -1.0 down to x0.0. Those are not cheap teams; they are the
    # exact value this whole guard exists to stop reaching `turf_score`, which
    # `SlateMatchup` validates at >= 1.0 and which pays a player nothing.
    #
    # It also kept `price_band` from being able to follow the table honestly.
    # The band's CEILING tracks this set, but its FLOOR is structural (x1.0 at
    # rank 1) and must NOT: deriving the floor from a negative scale would open
    # the guard to the zero it was written to refuse. Dropping the row here is
    # what lets both be true at once — measured before this line existed, a
    # resolved scale of -5.0 put 31 of 32 board rows outside the band and -1.0
    # put 30 of 32, every one of them a price no write could have stored anyway.
    offered = Array(resolved_scale).map(&:to_f).select { |scale| scale >= SLIDER_SCALES.min }
    scales = SLIDER_SCALES + offered
    lines = factors.uniq.index_by { |factor| price_key(factor) }

    scales.each_with_object({}) do |scale, table|
      key = price_key(scale)
      # A resolved scale that lands ON the grid is already covered; the slider
      # position wins so the table holds one row per key.
      next if table.key?(key)

      table[key] = lines.transform_values do |factor|
        (1..teams).map do |rank|
          SlateMatchup.turf_score_for(rank, teams, sport: slate.sport, game_factor: factor, scale: scale)
        end
      end
    end
  end
end
