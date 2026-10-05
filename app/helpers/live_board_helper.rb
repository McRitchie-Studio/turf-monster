# Colour helpers the live board's partials share.
module LiveBoardHelper
  # A TEAM'S TWO COLOURS, RUN TOGETHER — the ink for a line that is about that
  # team: the down while it has the ball, the detail of a play it ran. Its
  # accent into its field colour, so Detroit reads silver into Honolulu blue.
  #
  # A field colour too dark to read on the board's dark surfaces (Atlanta's and
  # Las Vegas's are pure black) is lifted toward white rather than left as ink
  # nobody can see; a readable one is used as it is.
  #
  # Returns a CSS gradient, for `background` under `background-clip: text`.
  def team_two_tone_ink(team)
    accent = team_card_palette(team)[:accent]
    field = normalize_hex(team&.card_background)
    field = "color-mix(in srgb, #{field} 45%, #ffffff)" if field && relative_luminance(field) < 0.1

    "linear-gradient(90deg, #{accent}, #{field || accent})"
  end
end
