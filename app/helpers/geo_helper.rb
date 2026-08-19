module GeoHelper
  US_STATES = {
    "Alabama" => "AL", "Alaska" => "AK", "Arizona" => "AZ", "Arkansas" => "AR",
    "California" => "CA", "Colorado" => "CO", "Connecticut" => "CT", "Delaware" => "DE",
    "Florida" => "FL", "Georgia" => "GA", "Hawaii" => "HI", "Idaho" => "ID",
    "Illinois" => "IL", "Indiana" => "IN", "Iowa" => "IA", "Kansas" => "KS",
    "Kentucky" => "KY", "Louisiana" => "LA", "Maine" => "ME", "Maryland" => "MD",
    "Massachusetts" => "MA", "Michigan" => "MI", "Minnesota" => "MN", "Mississippi" => "MS",
    "Missouri" => "MO", "Montana" => "MT", "Nebraska" => "NE", "Nevada" => "NV",
    "New Hampshire" => "NH", "New Jersey" => "NJ", "New Mexico" => "NM", "New York" => "NY",
    "North Carolina" => "NC", "North Dakota" => "ND", "Ohio" => "OH", "Oklahoma" => "OK",
    "Oregon" => "OR", "Pennsylvania" => "PA", "Rhode Island" => "RI", "South Carolina" => "SC",
    "South Dakota" => "SD", "Tennessee" => "TN", "Texas" => "TX", "Utah" => "UT",
    "Vermont" => "VT", "Virginia" => "VA", "Washington" => "WA", "West Virginia" => "WV",
    "Wisconsin" => "WI", "Wyoming" => "WY",
    "District of Columbia" => "DC", "Puerto Rico" => "PR"
  }.freeze

  def normalize_state_code(raw)
    return nil if raw.blank?
    return raw.upcase if raw.match?(/\A[A-Za-z]{2}\z/)

    US_STATES[raw] || raw
  end

  # The visitor's country flag, as a regional-indicator emoji pair.
  #
  # Why an emoji rather than an asset: public/state-flags/ holds US states only,
  # so every non-US visitor fell through it to NO flag — an operator screenshot
  # showed a Canadian IP rendering as bare "Alberta" and a UK IP as "England".
  # Shipping ~250 country SVGs to fix that is a lot of bytes for a 16px badge,
  # and every platform already ships the glyphs.
  #
  # Returns nil for anything that is not exactly two ASCII letters, so a blank,
  # a malformed code, or a full country name renders text-only rather than
  # emitting garbage codepoints.
  def country_flag_emoji(alpha2)
    return nil if alpha2.blank?

    code = alpha2.to_s.strip.upcase
    return nil unless code.match?(/\A[A-Z]{2}\z/)

    # Regional Indicator Symbol A is U+1F1E6; the pair renders as one flag.
    code.chars.map { |c| c.ord - "A".ord + 0x1F1E6 }.pack("U*")
  end

  # True when the visitor is outside the US, and therefore must NOT be given a
  # US state flag. This is the load-bearing half: `state_flag_path` matches on a
  # bare two-letter code, so an Italian region normalising to "CA" would
  # otherwise be shown the CALIFORNIA flag — a wrong answer that looks right.
  def foreign_geo?(country)
    country.present? && country.to_s.strip.upcase != "US"
  end

  def state_flag_path(code)
    return nil if code.blank?

    path = "state-flags/#{code.downcase}.svg"
    File.exist?(Rails.root.join("public", path)) ? "/#{path}" : nil
  end
end
