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
  SLIDER_SCALES = (0..20).map { |step| (step * 0.5).round(1) }.freeze

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

    scales = SLIDER_SCALES + Array(resolved_scale).map(&:to_f)
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
