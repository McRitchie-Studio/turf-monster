# Presentation colors for team cards. Teams carry brand hex keyed by intrinsic
# lightness — color_dark / color_light, each with an alt — plus a
# color_disposition that says which color is the FIELD (see Team#card_background
# and Team#card_mascot). This helper turns those into ready-to-use CSS: a
# team-hue gradient, a readable foreground, the mascot color, a legibility halo,
# and a location line that stays readable on either field.
module TeamColorsHelper
  DARK_FG           = "#0f1216".freeze # foreground on a LIGHT field (gold Saints)
  LIGHT_FG          = "#ffffff".freeze # foreground on a DARK field
  FALLBACK_PRIMARY  = "#3a3f4b".freeze # neutral when a team has no brand color
  DEFAULT_TEAM_GREY = "#9aa0a6".freeze # the OPPONENTS grey when a team curates none

  # A mascot this dark (Falcons/Bengals black, Panthers/Saints near-black) would
  # vanish against a dark halo, so it — and only it — takes the light halo. WCAG
  # luminance in [0,1]; 0.06 sits just above #101820 yet well below any real
  # brand hue, so orange/red/gold mascots keep the dark halo.
  NEAR_BLACK_LUMINANCE = 0.06

  # Above this luminance a field reads as LIGHT (dark foreground + dark location
  # alt). Only the gold Saints/Steelers fields clear it; every other field —
  # including the red/orange light-disposition cards — stays dark.
  LIGHT_FIELD_LUMINANCE = 0.4

  # Ready-to-use CSS values for one team card. Keys map straight onto inline
  # style attributes in contests/_multi_week_team_card.
  def team_card_palette(team)
    bg          = normalize_hex(team&.card_background) || FALLBACK_PRIMARY
    mascot      = normalize_hex(team&.card_mascot) || LIGHT_FG
    light_field = relative_luminance(bg) > LIGHT_FIELD_LUMINANCE
    fg          = light_field ? DARK_FG : LIGHT_FG
    # The city line rides the light-family alt, swapping to the dark-family alt on
    # a light-disposition field — the same swap the mascot makes. Falls back to
    # the foreground when a team curates neither alt.
    location    = if team&.disposition_light?
      normalize_hex(team&.dark_alt) || fg
    else
      normalize_hex(team&.light_alt) || fg
    end

    {
      gradient: team_gradient(bg, light_field),
      fg: fg,
      fg_soft: rgba(fg, 0.72),   # week-opponent fallback
      fg_faint: rgba(fg, 0.55),  # labels: "Points", week headers
      border: rgba(fg, 0.18),    # card edge
      divider: rgba(fg, 0.14),   # week-row rules
      accent: mascot,            # the mascot
      location: location,        # the city line
      grey: normalize_hex(team&.color_grey) || DEFAULT_TEAM_GREY, # OPPONENTS strip
      # Holographic hover/select tint: the alt color when present, else the light.
      glow: normalize_hex(team&.color_alt) || normalize_hex(team&.color_light) || mascot,
      # Hold-button fizz: the team's brand colors, light then dark then alt. The
      # card wears the disposition-swapped background/mascot; the fizz wants them
      # raw, so six picks dress the button in eighteen team colors. Most teams
      # curate no alt and fall back to their dark — the third color is a flourish
      # where a team has one (the Ravens' red, the Buccaneers' orange).
      fizz_light: normalize_hex(team&.color_light) || mascot,
      fizz_dark: normalize_hex(team&.color_dark) || bg,
      fizz_alt: normalize_hex(team&.color_alt) || normalize_hex(team&.color_dark) || bg,
      mascot_shadow: mascot_shadow(mascot) # legibility halo on the gradient
    }
  end

  # A subtle halo that keeps the mascot legible on the team gradient: a light
  # halo behind an essentially-black mascot, a dark halo behind everything else.
  # Held at 0.5 alpha so it reads as a soft glow, not a hard sticker outline.
  def mascot_shadow(mascot)
    hex = normalize_hex(mascot)
    return "none" unless hex

    halo = relative_luminance(hex) < NEAR_BLACK_LUMINANCE ? "rgba(255, 255, 255, 0.5)" : "rgba(0, 0, 0, 0.5)"
    "0 0 2px #{halo}, 0 1px 2px #{halo}"
  end

  # The color for an opponent's short name on a team card. Adaptive: the
  # opponent's LIGHT color reads on a dark host field, its DARK color reads on a
  # light (gold) host field — so a near-black-accent team like the Saints shows
  # its gold on a dark card and its near-black on a gold card.
  def opponent_label_color(opponent, card_team)
    return nil unless opponent

    host_bg = normalize_hex(card_team&.card_background) || FALLBACK_PRIMARY
    if relative_luminance(host_bg) > LIGHT_FIELD_LUMINANCE
      normalize_hex(opponent.color_dark) || FALLBACK_PRIMARY
    else
      normalize_hex(opponent.color_light) || LIGHT_FG
    end
  end

  # A vertical gradient in the team's own field hue. Light fields stay airy;
  # dark fields gain depth toward the bottom.
  def team_gradient(field, light)
    top    = lighten_hex(field, light ? 0.12 : 0.06)
    bottom = darken_hex(field, light ? 0.10 : 0.32)
    "linear-gradient(160deg, #{top} 0%, #{field} 45%, #{bottom} 100%)"
  end

  # --- pure color math (hex in, css out) ------------------------------------

  def normalize_hex(hex)
    return nil if hex.blank?

    h = hex.to_s.strip.delete_prefix("#")
    h = h.chars.map { |c| c * 2 }.join if h.length == 3
    return nil unless h.match?(/\A[0-9a-fA-F]{6}\z/)

    "##{h.downcase}"
  end

  def hex_to_rgb(hex)
    h = normalize_hex(hex)
    return [0, 0, 0] unless h

    h = h.delete_prefix("#")
    [h[0, 2], h[2, 2], h[4, 2]].map { |pair| pair.to_i(16) }
  end

  def lighten_hex(hex, amount)
    r, g, b = hex_to_rgb(hex)
    rgb_to_hex(r + ((255 - r) * amount), g + ((255 - g) * amount), b + ((255 - b) * amount))
  end

  def darken_hex(hex, amount)
    r, g, b = hex_to_rgb(hex)
    rgb_to_hex(r * (1 - amount), g * (1 - amount), b * (1 - amount))
  end

  def rgba(hex, alpha)
    r, g, b = hex_to_rgb(hex)
    "rgba(#{r}, #{g}, #{b}, #{alpha})"
  end

  # WCAG relative luminance + contrast ratio, used to keep the mascot legible.
  def relative_luminance(hex)
    r, g, b = hex_to_rgb(hex).map do |channel|
      cs = channel / 255.0
      cs <= 0.03928 ? cs / 12.92 : (((cs + 0.055) / 1.055)**2.4)
    end
    (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
  end

  def contrast_ratio(hex1, hex2)
    lum = [relative_luminance(hex1), relative_luminance(hex2)]
    (lum.max + 0.05) / (lum.min + 0.05)
  end

  private

  def rgb_to_hex(r, g, b)
    format("#%02x%02x%02x", clamp255(r), clamp255(g), clamp255(b))
  end

  def clamp255(value)
    value.round.clamp(0, 255)
  end
end
