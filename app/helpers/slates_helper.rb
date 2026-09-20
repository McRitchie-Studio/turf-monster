module SlatesHelper
  # Every price the multiplier slider can produce, computed in Ruby.
  #
  # The slider is a range input with min 0, max 10 and step 0.5 — 21 positions,
  # not a continuum — so the whole space of prices it can show is small enough
  # to hand the page outright. The admin board then LOOKS UP a price instead of
  # recomputing one, which is what keeps the displayed number and the saved
  # number identical to what the curve pays: "Save Multipliers" posts the text
  # on screen, so a second implementation that rounds a tie differently writes a
  # price the rule never produced.
  #
  # Shape: { "2.5" => { "1.0" => [rank1, rank2, …], "1.5" => [...] } }, string
  # keys because they are read back from JS through the same `toFixed(1)` that
  # labels the slider.
  SLIDER_SCALES = (0..20).map { |step| (step * 0.5).round(1) }.freeze

  def turf_score_scale_table(slate:, teams:, factors:)
    return {} if teams.to_i < 1

    SLIDER_SCALES.index_with do |scale|
      factors.uniq.index_with do |factor|
        (1..teams).map do |rank|
          SlateMatchup.turf_score_for(rank, teams, sport: slate.sport, game_factor: factor, scale: scale)
        end
      end.transform_keys { |factor| format("%.1f", factor) }
    end.transform_keys { |scale| format("%.1f", scale) }
  end
end
