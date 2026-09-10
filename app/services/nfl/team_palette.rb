module Nfl
  # Single source of truth for NFL team brand colors. Both the NFL seed and the
  # `nfl:recolor` post-deploy task read PALETTE, so a color change reaches
  # production by recoloring EXISTING team rows — without re-running the games /
  # slates seed, which would re-freeze live turf_scores and re-price open picks.
  #
  # Colors are named by INTRINSIC LIGHTNESS, each with a same-family alt:
  #   dark        → the team's darker brand color
  #   light       → the team's lighter brand color
  #   dark_alt    → a second dark neutral ("" = none, defaults to `dark`)
  #   light_alt   → a second light neutral ("" = none, defaults to `light`)
  #   alt         → an extra brand color that fits no family ("" = none, no
  #                 behavior yet — a parking spot, e.g. the Ravens' red)
  #   grey        → the team's standard grey ("" = none → a neutral default);
  #                 drives the OPPONENTS strip on the multi-week card
  #   disposition → which color is the card FIELD: "dark" (bg=dark, mascot=light)
  #                 or "light" (bg=light, mascot=dark). Every NFL team currently
  #                 rides its dark field; disposition stays available for future
  #                 light-field teams and the FIFA set.
  # Sourced from teamcolorcodes.com; a few carry deliberate creative choices.
  module TeamPalette
    PALETTE = {
      "ARI" => { dark: "#97233F", light: "#FFB612", dark_alt: "#000000", light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      "ATL" => { dark: "#000000", light: "#A71930", dark_alt: "",        light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      # Creative: red parked in `alt` (never read right as a light-alt); white light-alt.
      "BAL" => { dark: "#241773", light: "#9E7C0C", dark_alt: "#000000", light_alt: "#FFFFFF", alt: "#C60C30", grey: "", disposition: "dark" },
      "BUF" => { dark: "#00338D", light: "#C60C30", dark_alt: "#041E42", light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      "CAR" => { dark: "#101820", light: "#0085CA", dark_alt: "",        light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      "CHI" => { dark: "#0B162A", light: "#C83803", dark_alt: "",        light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      "CIN" => { dark: "#000000", light: "#FB4F14", dark_alt: "",        light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      "CLE" => { dark: "#311D00", light: "#FF3C00", dark_alt: "",        light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      # Creative: darkest navy field, brand navy in the dark-alt, grey mascot.
      "DAL" => { dark: "#041E42", light: "#7F9695", dark_alt: "#003594", light_alt: "#869397", alt: "",        grey: "", disposition: "dark" },
      "DEN" => { dark: "#002244", light: "#FB4F14", dark_alt: "",        light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      "DET" => { dark: "#0076B6", light: "#B0B7BC", dark_alt: "#000000", light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      "GB"  => { dark: "#203731", light: "#FFB612", dark_alt: "",        light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      "HOU" => { dark: "#03202F", light: "#A71930", dark_alt: "",        light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      "IND" => { dark: "#002C5F", light: "#FFFFFF", dark_alt: "",        light_alt: "",        alt: "",        grey: "", disposition: "dark" },
      "JAX" => { dark: "#006778", light: "#D7A22A", dark_alt: "#101820", light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      "KC"  => { dark: "#E31837", light: "#FFB81C", dark_alt: "",        light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      "LAC" => { dark: "#0080C6", light: "#FFC20E", dark_alt: "",        light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      "LAR" => { dark: "#003594", light: "#FFA300", dark_alt: "",        light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      # Creative: white added at the light-alt.
      "LV"  => { dark: "#000000", light: "#A5ACAF", dark_alt: "",        light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      # Creative: dark-teal field (old alt-dark) with the classic teal as its alt.
      "MIA" => { dark: "#005778", light: "#FC4C02", dark_alt: "#008E97", light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      "MIN" => { dark: "#4F2683", light: "#FFC62F", dark_alt: "#000000", light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      "NE"  => { dark: "#002244", light: "#C60C30", dark_alt: "",        light_alt: "#B0B7BC", alt: "",        grey: "", disposition: "dark" },
      "NO"  => { dark: "#101820", light: "#D3BC8D", dark_alt: "",        light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      # Creative: white "Giants" mascot; old red moved to `alt`.
      "NYG" => { dark: "#0B2265", light: "#FFFFFF", dark_alt: "",        light_alt: "",        alt: "#A71930", grey: "", disposition: "dark" },
      "NYJ" => { dark: "#125740", light: "#FFFFFF", dark_alt: "",        light_alt: "",        alt: "",        grey: "", disposition: "dark" },
      # Creative: white "Eagles" mascot, old silver becomes the location alt.
      "PHI" => { dark: "#004C54", light: "#FFFFFF", dark_alt: "#000000", light_alt: "#A5ACAF", alt: "",        grey: "", disposition: "dark" },
      "PIT" => { dark: "#101820", light: "#FFB612", dark_alt: "",        light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      "SEA" => { dark: "#002244", light: "#69BE28", dark_alt: "",        light_alt: "#A5ACAF", alt: "",        grey: "", disposition: "dark" },
      "SF"  => { dark: "#AA0000", light: "#B3995D", dark_alt: "#000000", light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      # Creative: pewter field with a red "Buccaneers" mascot; orange parked in alt.
      "TB"  => { dark: "#3E3C3B", light: "#D50A0A", dark_alt: "#000000", light_alt: "#B1BABF", alt: "#FF7900", grey: "", disposition: "dark" },
      "TEN" => { dark: "#0C2340", light: "#4B92DB", dark_alt: "",        light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" },
      "WAS" => { dark: "#5A1414", light: "#FFB612", dark_alt: "",        light_alt: "#FFFFFF", alt: "",        grey: "", disposition: "dark" }
    }.freeze

    # The color attributes for one PALETTE row, ready for assign_attributes /
    # update!. "" collapses to nil so a blank slot stores as NULL.
    def self.attributes_for(abbr)
      colors = PALETTE.fetch(abbr)
      {
        color_dark: colors[:dark],
        color_light: colors[:light],
        color_dark_alt: colors[:dark_alt].to_s.presence,
        color_light_alt: colors[:light_alt].to_s.presence,
        color_alt: colors[:alt].to_s.presence,
        color_grey: colors[:grey].to_s.presence,
        color_disposition: colors.fetch(:disposition, "dark")
      }
    end

    # Upsert ONLY the color columns onto existing NFL team rows (matched by
    # short_name WITHIN the nfl scope, so a same-abbreviation non-NFL team can
    # never be recolored). Safe for production: touches no games, slates, or
    # rankings — and no non-NFL rows. ATOMIC: all 32 updates commit together or
    # not at all, so a mid-run failure never leaves a half-recolored league.
    # Returns the number of teams recolored.
    def self.apply!(scope = Team.nfl)
      ActiveRecord::Base.transaction do
        PALETTE.keys.count do |abbr|
          team = scope.find_by(short_name: abbr)
          team&.update!(attributes_for(abbr)) ? true : false
        end
      end
    end
  end
end
